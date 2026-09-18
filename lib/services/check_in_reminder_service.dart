import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/check_in_goal.dart';
import '../models/check_in_reminder.dart';
import 'app_log_service.dart';
import 'reminder_platform.dart';

/// 打卡目标的每日提醒。
///
/// 与写日记提醒的区别是**多实例**：每个目标一份设置、一个通知 id。其余硬约束一致：
/// - 重复交给系统的 `matchDateTimeComponents: DateTimeComponents.time`，不自建续订链；
/// - 时区不可用时拒绝排程，绝不回退 UTC；
/// - 只创建通知通道，从不删除；
/// - 没有精确闹钟权限时降级为 `inexactAllowWhileIdle`。
///
/// 设置**存在本机**、按目标 id 索引，不参与 Git 同步（原因见 `CheckInReminderSettings`）。
///
/// **已知边界：日期区间只在 Dart 侧、且只在 [reconcile] 时生效。** 原因是双重的：
/// fork 的原生 `FlutterLocalNotificationsPlugin.zonedSchedule` 在
/// `matchDateTimeComponents != null` 时会用"今天/明天 + 时分秒"整个替换掉传入的
/// `scheduledDateTime`（即首触发日期被丢弃），而系统侧的每日重复是无条件自续期的，
/// 插件也没有"结束时间"参数。所以：
/// - 开始日**之前**不会提醒，且开始日之后**必须打开过一次 App**（触发 reconcile）
///   才会开始提醒——把首触发时刻推到开始日这条思路在 Dart 层做不到，别试；
/// - 结束日**之后**会继续每天提醒，直到下一次打开 App 触发 reconcile 把它取消。
///
/// 不要为了收窄这个边界引入 `alarm_manager_plus` / 后台 isolate（历史静默失效的根因），
/// 也不要改成一次性闹钟逐日铺排——App 长期不开就会静默不响。
class CheckInReminderService {
  const CheckInReminderService._();

  static const String channelId = 'check_in_reminder_v1';
  static const String channelName = '打卡提醒';
  static const String channelDescription = '打卡目标提醒';
  static const String smallIcon = 'ic_stat_check_in_reminder';
  static const String logSource = 'check_in_reminder';

  static const String _payloadPrefix = 'check_in_reminder:';
  static const String _tapRouteKey = 'check_in_reminder';

  /// 通知 id 段。写日记提醒占用 2001 / 2002，这里另开一段避免撞号。
  /// 上限 100 个目标带提醒，够个人自用；用尽时明确报错而不是静默失败。
  static const int _idMin = 2200;
  static const int _idMax = 2299;

  /// 目标 id 是毫秒时间戳字符串，不能直接当通知 id（溢出 int32 且可能冲突），
  /// 所以维护一张 goalId → 通知 id 的分配表。
  static const String _idMapKey = 'check_in_reminder_ids';

  static const List<String> _settingSuffixes = <String>[
    'enabled',
    'hour',
    'minute',
    'name',
    'start',
    'end',
    'archived',
  ];

  /// `resumed` 可能连续触发，节流避免无谓的插件往返。
  static const Duration _reconcileMinInterval = Duration(seconds: 30);

  static bool _initialized = false;
  static Future<void>? _initializationFuture;
  static DateTime? _lastReconcileAt;

  /// 通知 id → 上次排程时的配置指纹。进程内有效；冷启动为空，
  /// 于是每次启动都会重新登记一遍（这正是"ROM 清掉排程后能自愈"的机制）。
  static final Map<int, String> _fingerprints = <int, String>{};

  @visibleForTesting
  static void resetForTesting() {
    _initialized = false;
    _initializationFuture = null;
    _lastReconcileAt = null;
    _fingerprints.clear();
  }

  // ---------------------------------------------------------------- 初始化

  static Future<void> initialize() => _initializationFuture ??= _initialize();

  static Future<void> _initialize() async {
    if (!ReminderPlatform.isAndroid) {
      _initialized = true;
      return;
    }
    try {
      // 插件由共用层初始化（全局只能初始化一次）
      final ready = await ReminderPlatform.ensureInitialized();
      if (!ready) {
        _initialized = true;
        return;
      }
      // 只创建，不删除：已有通道不重建，尊重用户在系统里的设置。
      await ReminderPlatform.backend.createChannel(
        const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.high,
        ),
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '打卡提醒初始化失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
    _initialized = true;
    await reconcile(force: true);
  }

  // ------------------------------------------------------------ 设置读写

  static Future<CheckInReminderSettings> loadSettings(String goalId) =>
      _loadSettings(goalId);

  /// 保存某个目标的提醒设置，并立刻把排程对齐。
  static Future<CheckInReminderResult> saveSettings(
    CheckInReminderSettings settings,
  ) async {
    if (!ReminderPlatform.isAndroid) {
      return const CheckInReminderResult.failed('当前平台不支持提醒');
    }
    await initialize();

    final ids = await _loadIdMap();
    if (settings.enabled && !ids.containsKey(settings.goalId)) {
      final allocated = _allocateId(ids);
      if (allocated == null) {
        return const CheckInReminderResult.failed(
          '带提醒的目标数量已达上限（100 个），请先关掉一些目标的提醒',
        );
      }
      ids[settings.goalId] = allocated;
    }
    await _saveIdMap(ids);
    await _persist(settings);

    // 用户刚打开开关，是申请通知权限的合适时机
    if (settings.enabled) {
      await _requestPermissionIfNeeded();
    }

    final failed = await reconcile(force: true);
    if (settings.enabled && failed.contains(settings.goalId)) {
      // 排程这一步抛了异常，设置虽然存下了但不会响。必须如实说，
      // 否则开关停在一个"看起来开着"的状态里。
      return const CheckInReminderResult.failed(
        '提醒排程失败，设置已保存但暂时不会响。请查看运行日志',
      );
    }
    return _evaluate(settings);
  }

  /// 删除某个目标的提醒（目标被删除时调用）。
  static Future<void> removeSettings(String goalId) async {
    final ids = await _loadIdMap();
    final notificationId = ids.remove(goalId);
    if (notificationId != null) {
      await ReminderPlatform.safe(
        () => ReminderPlatform.backend.cancel(id: notificationId),
      );
      _fingerprints.remove(notificationId);
    }
    await _saveIdMap(ids);

    final prefs = await SharedPreferences.getInstance();
    for (final suffix in _settingSuffixes) {
      await prefs.remove(_settingKey(goalId, suffix));
    }
  }

  // ---------------------------------------------------------------- 点击

  /// 绑定点击处理，回调收到的是目标 id。
  static void bindTapHandler(void Function(String goalId) handler) {
    ReminderPlatform.registerTapHandler(
      _tapRouteKey,
      matches: (payload) =>
          payload != null && payload.startsWith(_payloadPrefix),
      handler: (payload) =>
          handler(payload!.substring(_payloadPrefix.length)),
    );
  }

  // -------------------------------------------------------------- 排程对齐

  /// 把实际排程对齐到"应该存在的提醒集合"。
  ///
  /// [allGoals] **必须是完整的目标列表**：非空时会取消那些目标已不存在的提醒，
  /// 传部分列表会把没列进来的目标的提醒全部误删。这是「另一端删了目标并同步过来」
  /// 的唯一清理时机——本地偏好里的孤儿项否则会一直提醒下去。
  /// 传 null 时只用本地偏好判断（回到前台的自检走这条，不需要加载整份文档）。
  ///
  /// 返回**排程调用抛错的目标 id**。[_schedule] 内部把异常降级成日志，所以调用方
  /// 只能靠这个集合判断"到底登记上没有"，不能靠本方法是否正常返回。
  /// 被节流、非 Android、未初始化时会提前返回空集——空集只表示"没有失败记录"，
  /// 不表示全部成功；需要确切答案的调用方必须传 `force: true`。
  static Future<Set<String>> reconcile({
    List<CheckInGoal>? allGoals,
    bool force = false,
  }) async {
    if (!ReminderPlatform.isAndroid || !_initialized) return const <String>{};

    final now = DateTime.now();
    final last = _lastReconcileAt;
    if (!force &&
        last != null &&
        now.difference(last) < _reconcileMinInterval) {
      return const <String>{};
    }
    _lastReconcileAt = now;

    final backend = ReminderPlatform.backend;
    final ids = await _loadIdMap();

    if (allGoals != null) {
      await _refreshFromGoals(allGoals, ids);
    }

    final pending = await ReminderPlatform.safe(
          () => backend.pendingNotificationRequests(),
        ) ??
        const <PendingNotificationRequest>[];
    final ourPending = pending
        .where((request) => request.id >= _idMin && request.id <= _idMax)
        .map((request) => request.id)
        .toSet();

    final timezoneName = ReminderPlatform.timezoneName;
    final exactAllowed = await ReminderPlatform.safeBool(
      () => backend.canScheduleExactNotifications(),
    );
    final notificationsAllowed = await ReminderPlatform.safeBool(
      () => backend.areNotificationsEnabled(),
      fallback: true,
    );

    final failedGoalIds = <String>{};
    var desired = 0;
    var scheduled = 0;
    var cancelled = 0;

    for (final goalId in ids.keys.toList()) {
      final notificationId = ids[goalId];
      if (notificationId == null) continue;
      final settings = await _loadSettings(goalId);
      final shouldExist = settings.isEligibleAt(DateTime.now());

      if (!shouldExist) {
        // 无条件取消：插件对不存在的 id 是无操作，而"只在 pending 里才取消"
        // 会在 pending 读不到时让已关闭/已归档的提醒一直响下去。
        await ReminderPlatform.safe(() => backend.cancel(id: notificationId));
        if (ourPending.contains(notificationId)) cancelled++;
        _fingerprints.remove(notificationId);
        continue;
      }

      desired++;
      // 没有可信时区就不排程；通知被禁时排了也不会显示
      if (timezoneName == null || !notificationsAllowed) continue;

      final fingerprint = _fingerprint(settings, exactAllowed);
      if (ourPending.contains(notificationId) &&
          _fingerprints[notificationId] == fingerprint) {
        scheduled++;
        continue;
      }
      if (await _schedule(settings, notificationId, exactAllowed)) {
        scheduled++;
        _fingerprints[notificationId] = fingerprint;
      } else {
        failedGoalIds.add(goalId);
      }
    }

    _logSelfCheck(
      allGoals == null ? 'reconcile_prefs' : 'reconcile_goals',
      desired: desired,
      scheduled: scheduled,
      cancelled: cancelled,
      pending: ourPending.length,
      exact: exactAllowed,
      notifications: notificationsAllowed,
      timezone: timezoneName,
    );

    return failedGoalIds;
  }

  /// 单个目标变化后更新它的提醒（不需要完整目标列表）。
  ///
  /// 归档、到期这类变化会体现在冗余字段里，从而被 [reconcile] 取消掉。
  static Future<void> syncGoal(CheckInGoal goal) async {
    if (!ReminderPlatform.isAndroid) return;
    await initialize();
    final stored = await _loadSettings(goal.id);
    if (!stored.enabled) return;
    final refreshed = stored.copyWith(
      goalName: goal.name,
      startDateMs: goal.startDate?.millisecondsSinceEpoch,
      endDateMs: goal.endDate?.millisecondsSinceEpoch,
      archived: goal.isArchived,
    );
    if (refreshed != stored) await _persist(refreshed);
    await reconcile(force: true);
  }

  /// 用真实目标列表刷新冗余字段，并清掉已不存在目标的提醒。
  static Future<void> _refreshFromGoals(
    List<CheckInGoal> goals,
    Map<String, int> ids,
  ) async {
    final byId = <String, CheckInGoal>{
      for (final goal in goals) goal.id: goal,
    };

    for (final goalId in ids.keys.toList()) {
      final goal = byId[goalId];
      if (goal == null) {
        await removeSettings(goalId);
        ids.remove(goalId);
        continue;
      }
      final stored = await _loadSettings(goalId);
      if (!stored.enabled) continue;
      final refreshed = stored.copyWith(
        goalName: goal.name,
        startDateMs: goal.startDate?.millisecondsSinceEpoch,
        endDateMs: goal.endDate?.millisecondsSinceEpoch,
        archived: goal.isArchived,
      );
      if (refreshed != stored) await _persist(refreshed);
    }
  }

  static Future<bool> _schedule(
    CheckInReminderSettings settings,
    int notificationId,
    bool exactAllowed,
  ) async {
    final backend = ReminderPlatform.backend;
    // 先取消同 id，保证重复调用是幂等的
    await ReminderPlatform.safe(() => backend.cancel(id: notificationId));

    final next =
        ReminderPlatform.nextInstance(settings.hour, settings.minute);
    try {
      await backend.zonedSchedule(
        id: notificationId,
        title: settings.goalName.isEmpty ? '打卡提醒' : settings.goalName,
        body: '该打卡了，别忘了记录',
        scheduledDate: next,
        payload: '$_payloadPrefix${settings.goalId}',
        // 关键：由系统负责每日重复，不靠到点回调再排下一次
        matchDateTimeComponents: DateTimeComponents.time,
        notificationDetails: _notificationDetails(),
        scheduleMode: exactAllowed
            ? AndroidScheduleMode.exactAllowWhileIdle
            // 降级目标必须是"不精确"：exactAllowWhileIdle 同样需要精确闹钟权限
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '打卡提醒排程失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      _logSelfCheck(
        'schedule_failed',
        goalId: settings.goalId,
        reason: 'exception',
        timezone: ReminderPlatform.timezoneName,
      );
      return false;
    }

    _logSelfCheck(
      'schedule_registered',
      goalId: settings.goalId,
      next: next,
      exact: exactAllowed,
      timezone: ReminderPlatform.timezoneName,
    );
    return true;
  }

  // ---------------------------------------------------------------- 内部

  static AndroidNotificationDetails _notificationDetails() {
    return const AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      icon: smallIcon,
      playSound: true,
      enableVibration: true,
      autoCancel: true,
      // 默认就是 createIfNotExists：只创建，不重建，不覆盖用户设置
      channelAction: AndroidNotificationChannelAction.createIfNotExists,
    );
  }

  static String _fingerprint(
    CheckInReminderSettings settings,
    bool exactAllowed,
  ) {
    return '${settings.goalId}|${settings.hour}|${settings.minute}'
        '|${settings.goalName}|${ReminderPlatform.timezoneName ?? ''}'
        '|$exactAllowed';
  }

  static int? _allocateId(Map<String, int> ids) {
    final used = ids.values.toSet();
    for (var candidate = _idMin; candidate <= _idMax; candidate++) {
      if (!used.contains(candidate)) return candidate;
    }
    return null;
  }

  static Future<void> _requestPermissionIfNeeded() async {
    final backend = ReminderPlatform.backend;
    final allowed = await ReminderPlatform.safeBool(
      () => backend.areNotificationsEnabled(),
      fallback: true,
    );
    if (!allowed) {
      await ReminderPlatform.safe(
        () => backend.requestNotificationsPermission(),
      );
    }
  }

  /// 保存后把"实际上会不会响"如实告诉用户，而不是让开关停在一个不会响的状态。
  static Future<CheckInReminderResult> _evaluate(
    CheckInReminderSettings settings,
  ) async {
    if (!settings.enabled) return const CheckInReminderResult();

    if (ReminderPlatform.timezoneName == null) {
      return const CheckInReminderResult.failed(
        '系统时区读取失败，提醒已暂停（不会用 UTC 代替）。请检查系统时区后重试。',
      );
    }

    final backend = ReminderPlatform.backend;
    final allowed = await ReminderPlatform.safeBool(
      () => backend.areNotificationsEnabled(),
      fallback: true,
    );
    if (!allowed) {
      return const CheckInReminderResult.failed(
        '通知权限未授予，提醒不会显示。请在系统设置里允许通知。',
      );
    }

    final channel = await _lookupChannel();
    if (channel != null && channel.importance == Importance.none) {
      return const CheckInReminderResult(
        message: '已设置，但「打卡提醒」通知通道被关闭了，提醒不会显示',
      );
    }

    final exactAllowed = await ReminderPlatform.safeBool(
      () => backend.canScheduleExactNotifications(),
    );
    if (!exactAllowed) {
      return const CheckInReminderResult(
        message: '已设置，但缺少精确闹钟权限，提醒可能延迟几分钟',
      );
    }
    return const CheckInReminderResult();
  }

  static Future<AndroidNotificationChannel?> _lookupChannel() async {
    final channels = await ReminderPlatform.safe(
      () => ReminderPlatform.backend.getChannels(),
    );
    if (channels == null) return null;
    for (final channel in channels) {
      if (channel.id == channelId) return channel;
    }
    return null;
  }

  static String _settingKey(String goalId, String suffix) =>
      'check_in_reminder_${goalId}_$suffix';

  static Future<CheckInReminderSettings> _loadSettings(String goalId) async {
    final prefs = await SharedPreferences.getInstance();
    return CheckInReminderSettings(
      goalId: goalId,
      enabled: prefs.getBool(_settingKey(goalId, 'enabled')) ?? false,
      hour: prefs.getInt(_settingKey(goalId, 'hour')) ??
          CheckInReminderSettings.defaultHour,
      minute: prefs.getInt(_settingKey(goalId, 'minute')) ??
          CheckInReminderSettings.defaultMinute,
      goalName: prefs.getString(_settingKey(goalId, 'name')) ?? '',
      startDateMs: prefs.getInt(_settingKey(goalId, 'start')),
      endDateMs: prefs.getInt(_settingKey(goalId, 'end')),
      archived: prefs.getBool(_settingKey(goalId, 'archived')) ?? false,
    );
  }

  static Future<void> _persist(CheckInReminderSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      _settingKey(settings.goalId, 'enabled'),
      settings.enabled,
    );
    await prefs.setInt(_settingKey(settings.goalId, 'hour'), settings.hour);
    await prefs.setInt(
      _settingKey(settings.goalId, 'minute'),
      settings.minute,
    );
    await prefs.setString(
      _settingKey(settings.goalId, 'name'),
      settings.goalName,
    );
    final start = settings.startDateMs;
    if (start == null) {
      await prefs.remove(_settingKey(settings.goalId, 'start'));
    } else {
      await prefs.setInt(_settingKey(settings.goalId, 'start'), start);
    }
    final end = settings.endDateMs;
    if (end == null) {
      await prefs.remove(_settingKey(settings.goalId, 'end'));
    } else {
      await prefs.setInt(_settingKey(settings.goalId, 'end'), end);
    }
    await prefs.setBool(
      _settingKey(settings.goalId, 'archived'),
      settings.archived,
    );
  }

  static Future<Map<String, int>> _loadIdMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_idMapKey);
    if (raw == null || raw.trim().isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      final result = <String, int>{};
      decoded.forEach((key, value) {
        if (key is String && value is int) result[key] = value;
      });
      return result;
    } catch (error) {
      // 解析失败就从空表开始，最多是重新分配通知 id，不会造成错误提醒
      AppLogService.instance.warning(
        '打卡提醒通知 id 表解析失败，按空表处理',
        source: logSource,
        error: error,
      );
      return <String, int>{};
    }
  }

  static Future<void> _saveIdMap(Map<String, int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    if (ids.isEmpty) {
      await prefs.remove(_idMapKey);
      return;
    }
    await prefs.setString(_idMapKey, jsonEncode(ids));
  }

  /// 排程日志：阶段名 + 关键字段，供「运行日志」里自查。
  static void _logSelfCheck(
    String stage, {
    String? goalId,
    Object? next,
    String? reason,
    int? desired,
    int? scheduled,
    int? cancelled,
    int? pending,
    bool? exact,
    bool? notifications,
    String? timezone,
  }) {
    final buffer = StringBuffer('打卡提醒自检[$stage]: ')
      ..write('tz=${timezone ?? 'unavailable'}');
    if (goalId != null) buffer.write(', goal=$goalId');
    if (desired != null) buffer.write(', desired=$desired');
    if (scheduled != null) buffer.write(', scheduled=$scheduled');
    if (cancelled != null) buffer.write(', cancelled=$cancelled');
    if (pending != null) buffer.write(', pending=$pending');
    if (exact != null) buffer.write(', exact=$exact');
    if (notifications != null) buffer.write(', notif=$notifications');
    if (next != null) buffer.write(', next=$next');
    if (reason != null) buffer.write(', reason=$reason');
    AppLogService.instance.info(buffer.toString(), source: logSource);
  }
}
