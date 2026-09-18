import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/diary_reminder.dart';
import 'app_identity_service.dart';
import 'app_log_service.dart';

/// 通知插件的薄封装。抽出接口是为了让服务层可以在不触碰原生通道的情况下被测试。
abstract class DiaryReminderBackend {
  Future<bool> initialize(
    AndroidInitializationSettings settings, {
    required void Function(NotificationResponse response) onResponse,
  });

  Future<void> createChannel(AndroidNotificationChannel channel);

  Future<List<AndroidNotificationChannel>?> getChannels();

  Future<void> zonedSchedule({
    required int id,
    String? title,
    String? body,
    required tz.TZDateTime scheduledDate,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
    AndroidNotificationDetails? notificationDetails,
    AndroidScheduleMode scheduleMode,
  });

  Future<void> show({
    required int id,
    String? title,
    String? body,
    AndroidNotificationDetails? notificationDetails,
    String? payload,
  });

  Future<void> cancel({required int id});

  Future<List<PendingNotificationRequest>> pendingNotificationRequests();

  Future<bool?> canScheduleExactNotifications();

  Future<bool?> areNotificationsEnabled();

  Future<bool?> requestNotificationsPermission();

  Future<bool?> requestExactAlarmsPermission();

  Future<bool?> openAppNotificationSettings();

  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails();
}

class _AndroidDiaryReminderBackend implements DiaryReminderBackend {
  _AndroidDiaryReminderBackend() : _plugin = FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<bool> initialize(
    AndroidInitializationSettings settings, {
    required void Function(NotificationResponse response) onResponse,
  }) async {
    final android = _android;
    if (android == null) return false;
    return android.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: onResponse,
    );
  }

  @override
  Future<void> createChannel(AndroidNotificationChannel channel) async {
    await _android?.createNotificationChannel(channel);
  }

  @override
  Future<List<AndroidNotificationChannel>?> getChannels() =>
      _android?.getNotificationChannels() ?? Future.value(null);

  @override
  Future<void> zonedSchedule({
    required int id,
    String? title,
    String? body,
    required tz.TZDateTime scheduledDate,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
    AndroidNotificationDetails? notificationDetails,
    AndroidScheduleMode scheduleMode =
        AndroidScheduleMode.exactAllowWhileIdle,
  }) async {
    await _android?.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      payload: payload,
      matchDateTimeComponents: matchDateTimeComponents,
      notificationDetails: notificationDetails,
      scheduleMode: scheduleMode,
    );
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    AndroidNotificationDetails? notificationDetails,
    String? payload,
  }) async {
    await _android?.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
      payload: payload,
    );
  }

  @override
  Future<void> cancel({required int id}) async {
    await _android?.cancel(id: id);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() =>
      _plugin.pendingNotificationRequests();

  @override
  Future<bool?> canScheduleExactNotifications() =>
      _android?.canScheduleExactNotifications() ?? Future.value(null);

  @override
  Future<bool?> areNotificationsEnabled() =>
      _android?.areNotificationsEnabled() ?? Future.value(null);

  @override
  Future<bool?> requestNotificationsPermission() =>
      _android?.requestNotificationsPermission() ?? Future.value(null);

  @override
  Future<bool?> requestExactAlarmsPermission() =>
      _android?.requestExactAlarmsPermission() ?? Future.value(null);

  @override
  Future<bool?> openAppNotificationSettings() =>
      _android?.openAppNotificationSettings() ?? Future.value(null);

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() =>
      _android?.getNotificationAppLaunchDetails() ?? Future.value(null);
}

/// 写日记提醒：唯一的排程入口。
///
/// 设计要点（都是为了避免重演历史上的静默失效）：
/// - 重复交给系统的 `matchDateTimeComponents: DateTimeComponents.time`，不自建续订链；
/// - 不使用后台 isolate，不需要在后台引擎里反射注册插件；
/// - 时区不可用时**拒绝排程**，绝不静默回退 UTC；
/// - 只创建通知通道，从不删除；
/// - 所有对外方法都返回状态快照，UI 与日志依据状态而不是控制台输出判断成败。
class DiaryReminderService {
  const DiaryReminderService._();

  static const int notificationId = 2001;

  /// 与排定用的 ID 分开，测试通知不会覆盖已排程的提醒。
  static const int testNotificationId = 2002;

  /// 必须与旧实现用过的 `diary_reminder` 区分：原生 `createNotificationChannel`
  /// 无法把已存在通道的重要性改回高，复用旧 ID 会得到「能发但不弹横幅、不出声」。
  static const String channelId = 'diary_reminder_v2';
  static const String channelName = '写日记提醒';
  static const String channelDescription = '每天提醒写日记';
  static const String payload = 'diary_reminder';
  static const String smallIcon = 'ic_stat_diary_reminder';
  static const String logSource = 'diary_reminder';

  static const String _enabledBaseKey = 'diary_reminder_enabled';
  static const String _hourBaseKey = 'diary_reminder_hour';
  static const String _minuteBaseKey = 'diary_reminder_minute';

  /// `resumed` 可能连续触发，节流避免无谓的插件往返。
  static const Duration _ensureMinInterval = Duration(seconds: 30);

  static bool _initialized = false;
  static Future<DiaryReminderStatus>? _initializationFuture;
  static String? _timezoneName;
  static String? _scheduledFingerprint;
  static DateTime? _lastEnsureAt;
  static bool _coldStartHandled = false;
  static bool _pendingTap = false;
  static void Function()? _onOpenDiary;
  static StreamSubscription<void>? _identitySubscription;

  @visibleForTesting
  static DiaryReminderBackend? backendOverride;

  @visibleForTesting
  static bool? androidPlatformOverride;

  @visibleForTesting
  static Future<String> Function()? timezoneIdentifierOverride;

  @visibleForTesting
  static void resetForTesting() {
    backendOverride = null;
    androidPlatformOverride = null;
    timezoneIdentifierOverride = null;
    _initialized = false;
    _initializationFuture = null;
    _timezoneName = null;
    _scheduledFingerprint = null;
    _lastEnsureAt = null;
    _coldStartHandled = false;
    _pendingTap = false;
    _onOpenDiary = null;
    _identitySubscription?.cancel();
    _identitySubscription = null;
  }

  static DiaryReminderBackend get _backend =>
      backendOverride ?? _AndroidDiaryReminderBackend();

  /// 刻意不用 `defaultTargetPlatform`：flutter_test 默认把它当作 android，
  /// 会让既有测试意外走到平台调用路径。
  static bool get _isAndroid => androidPlatformOverride ?? Platform.isAndroid;

  // ---------------------------------------------------------------- 初始化

  /// 幂等初始化。返回的 Future 会被记住，重复调用不会重复初始化插件。
  static Future<DiaryReminderStatus> initialize() =>
      _initializationFuture ??= _initialize();

  static Future<DiaryReminderStatus> _initialize() async {
    if (!_isAndroid) {
      _initialized = true;
      return _status(issue: DiaryReminderIssue.unsupportedPlatform);
    }

    try {
      await _configureTimezone();

      await _backend.initialize(
        // 裸资源名即可：插件内部用 getIdentifier(name, "drawable", pkg) 解析，
        // 加 `@drawable/` 前缀反而会引入不必要的歧义。
        // 注意 initialize() 会校验这个资源，解析不到会直接报错（不会静默降级）。
        const AndroidInitializationSettings(smallIcon),
        onResponse: _handleResponse,
      );

      // 只创建，不删除：已有通道不重建，尊重用户在系统里的设置。
      await _backend.createChannel(
        const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.high,
        ),
      );

      // 身份切换后按新作用域重排。
      // 注意不要在回调里 await AppIdentityService.load()：_loadInternal 结尾会无条件
      // 通知变更，那样会构成 load → notify → ensureScheduled → load 的死循环。
      _identitySubscription ??= AppIdentityService.changes.listen((_) {
        unawaited(ensureScheduled(force: true));
      });
    } catch (error, stackTrace) {
      _initialized = true;
      AppLogService.instance.error(
        '写日记提醒初始化失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      return _status(
        issue: DiaryReminderIssue.scheduleFailed,
        message: '提醒初始化失败，请查看运行日志',
      );
    }

    _initialized = true;
    // 启动即补一次排程：强制停止后重开、ROM 清掉 pending 或进程重启都靠这一步恢复。
    return ensureScheduled(force: true);
  }

  /// 时区。失败时把 `_timezoneName` 留空，由调用方拒绝排程——绝不回退 UTC。
  static Future<void> _configureTimezone() async {
    tz_data.initializeTimeZones();
    String? identifier;
    try {
      identifier = timezoneIdentifierOverride != null
          ? await timezoneIdentifierOverride!()
          : (await FlutterTimezone.getLocalTimezone()).identifier;
    } catch (_) {
      identifier = null;
    }
    if (identifier == null || identifier.trim().isEmpty) {
      _timezoneName = null;
      return;
    }
    try {
      final location = tz.getLocation(identifier);
      tz.setLocalLocation(location);
      _timezoneName = location.name;
    } catch (_) {
      // 拿到的不一定是 IANA 名称。没有可信时区就不排程，
      // 用上一次的缓存假装成功会让提醒在错误的时间响。
      _timezoneName = null;
    }
  }

  // ------------------------------------------------------------ 设置读写

  static Future<DiaryReminderSettings> loadSettings() async {
    final prefs = await _prefs();
    return DiaryReminderSettings(
      enabled: prefs.getBool(_key(_enabledBaseKey)) ?? false,
      hour: prefs.getInt(_key(_hourBaseKey)) ??
          DiaryReminderSettings.defaultHour,
      minute: prefs.getInt(_key(_minuteBaseKey)) ??
          DiaryReminderSettings.defaultMinute,
    );
  }

  static Future<DiaryReminderStatus> saveSettings(
    DiaryReminderSettings next,
  ) async {
    if (!_isAndroid) {
      return _status(settings: next, issue: DiaryReminderIssue.unsupportedPlatform);
    }
    await initialize();

    if (!await _ensureIdentityLoaded()) {
      return _status(
        settings: next,
        issue: DiaryReminderIssue.identityUnavailable,
        message: '请先选择用户身份，再开启写日记提醒',
      );
    }

    final prefs = await _prefs();
    await prefs.setBool(_key(_enabledBaseKey), next.enabled);
    await prefs.setInt(_key(_hourBaseKey), next.hour);
    await prefs.setInt(_key(_minuteBaseKey), next.minute);

    if (!next.enabled) return _cancel(next);
    return _schedule(next);
  }

  /// 抽屉打开时读取。启用状态下顺便做一次幂等自检与补登记。
  static Future<DiaryReminderStatus> loadStatus() async {
    if (!_isAndroid) {
      return _status(issue: DiaryReminderIssue.unsupportedPlatform);
    }
    final init = await initialize();
    // 插件都没初始化成功时，后面的探测结果不可信，直接把失败如实报出去
    if (init.issue == DiaryReminderIssue.scheduleFailed) return init;

    final settings = await loadSettings();
    if (!settings.enabled) {
      return _status(settings: settings, issue: await _passiveIssue());
    }
    return ensureScheduled(force: true);
  }

  // -------------------------------------------------------------- 排程

  static Future<DiaryReminderStatus> _schedule(DiaryReminderSettings s) async {
    if (!_isAndroid) {
      return _status(settings: s, issue: DiaryReminderIssue.unsupportedPlatform);
    }
    if (!await _ensureIdentityLoaded()) {
      return _status(
        settings: s,
        issue: DiaryReminderIssue.identityUnavailable,
        message: '请先选择用户身份，再开启写日记提醒',
      );
    }
    if (_timezoneName == null) {
      return _status(
        settings: s,
        issue: DiaryReminderIssue.timezoneUnavailable,
        message: '系统时区读取失败，已暂停提醒（不会用 UTC 代替）。请检查系统时区后重试。',
      );
    }

    _logSelfCheck('schedule_attempt', s);

    final backend = _backend;
    final exactAllowed =
        await _safeBool(() => backend.canScheduleExactNotifications());
    final notificationAllowed =
        await _safeBool(() => backend.areNotificationsEnabled(), fallback: true);

    // 先取消同 ID，保证重复调用是幂等的
    await _safe(() => backend.cancel(id: notificationId));

    if (!notificationAllowed) {
      final status = _status(
        settings: s,
        issue: DiaryReminderIssue.notificationsDenied,
        message: '通知权限未授予，提醒无法显示。点按前往系统设置。',
        exactAllowed: exactAllowed,
      );
      _logSelfCheck('schedule_failed', s, reason: 'notifications_denied');
      return status;
    }

    final next = _nextInstance(s.hour, s.minute);
    try {
      await backend.zonedSchedule(
        id: notificationId,
        title: '写日记提醒',
        body: '该写日记了 — 记录今天的点滴吧',
        scheduledDate: next,
        payload: payload,
        // 关键：由系统负责每日重复，不靠到点回调再排下一次
        matchDateTimeComponents: DateTimeComponents.time,
        notificationDetails: _notificationDetails(),
        scheduleMode: exactAllowed
            ? AndroidScheduleMode.exactAllowWhileIdle
            // 注意降级目标是不精确模式：exactAllowWhileIdle 同样需要精确闹钟权限，
            // 用它等于没有降级。
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '写日记提醒排程失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      _logSelfCheck('schedule_failed', s, reason: 'exception');
      return _status(
        settings: s,
        issue: DiaryReminderIssue.scheduleFailed,
        message: '排程失败，请查看运行日志',
        exactAllowed: exactAllowed,
      );
    }

    _scheduledFingerprint = _fingerprint(s, exactAllowed);

    final channel = await _lookupChannel();
    var issue = exactAllowed
        ? DiaryReminderIssue.none
        : DiaryReminderIssue.exactAlarmDenied;

    if (channel != null && channel.importance == Importance.none) {
      issue = DiaryReminderIssue.channelDisabled;
    }

    final status = _status(
      settings: s,
      issue: issue,
      message: _issueMessage(issue, channel?.importance),
      scheduled: true,
      exactAllowed: exactAllowed,
      notificationAllowed: notificationAllowed,
      channelImportance: channel?.importance.value,
      nextFireAt: next,
    );
    _logSelfCheck('schedule_registered', s, status: status);
    return status;
  }

  static Future<DiaryReminderStatus> _cancel(DiaryReminderSettings s) async {
    final backend = _backend;
    _scheduledFingerprint = null;
    await _safe(() => backend.cancel(id: notificationId));
    final status = _status(settings: s);
    _logSelfCheck('cancelled', s, status: status);
    return status;
  }

  /// 幂等自检：pending 里没有本提醒、或配置指纹变了，就重新登记。
  static Future<DiaryReminderStatus> ensureScheduled({bool force = false}) async {
    if (!_isAndroid) {
      return _status(issue: DiaryReminderIssue.unsupportedPlatform);
    }
    if (!_initialized) {
      // 尚未初始化：既有测试与桌面路径都会走到这里，直接短路，不产生平台调用
      return _status();
    }
    final now = DateTime.now();
    final last = _lastEnsureAt;
    if (!force && last != null && now.difference(last) < _ensureMinInterval) {
      return _status();
    }
    _lastEnsureAt = now;

    if (!await _ensureIdentityLoaded()) {
      return _status(
        issue: DiaryReminderIssue.identityUnavailable,
        message: '请先选择用户身份，再开启写日记提醒',
      );
    }

    final s = await loadSettings();
    if (!s.enabled) return _status(settings: s);

    final backend = _backend;
    final pending = await _safe(() => backend.pendingNotificationRequests()) ??
        const <PendingNotificationRequest>[];
    final registered = pending.any((p) => p.id == notificationId);

    final exactAllowed =
        await _safeBool(() => backend.canScheduleExactNotifications());
    final fingerprintMatches =
        _scheduledFingerprint == _fingerprint(s, exactAllowed);

    final channel = await _lookupChannel();
    final notificationAllowed =
        await _safeBool(() => backend.areNotificationsEnabled(), fallback: true);
    final issue = _issueFor(
      exactAllowed: exactAllowed,
      channel: channel,
      notificationAllowed: notificationAllowed,
    );

    if (registered && fingerprintMatches) {
      final status = _status(
        settings: s,
        issue: issue,
        message: _issueMessage(issue, channel?.importance),
        scheduled: true,
        exactAllowed: exactAllowed,
        notificationAllowed: notificationAllowed,
        channelImportance: channel?.importance.value,
        nextFireAt: _nextInstance(s.hour, s.minute),
      );
      _logSelfCheck('pending_verified', s, status: status);
      return status;
    }

    // 排定被系统清掉，或身份/时区/权限变了：重新登记
    return _schedule(s);
  }

  // ------------------------------------------------------------ 权限与自检

  /// 申请通知权限；缺少精确闹钟能力时顺带引导。
  static Future<DiaryReminderStatus> requestPermissions() async {
    if (!_isAndroid) {
      return _status(issue: DiaryReminderIssue.unsupportedPlatform);
    }
    await initialize();
    final backend = _backend;
    await _safe(() => backend.requestNotificationsPermission());
    if (!await _safeBool(() => backend.canScheduleExactNotifications())) {
      await _safe(() => backend.requestExactAlarmsPermission());
    }
    final s = await loadSettings();
    if (!s.enabled) return _status(settings: s);
    return _schedule(s);
  }

  /// 跳转到对应的系统设置页：没有精确闹钟权限时去闹钟页，否则去通知页。
  static Future<void> openSystemSettings() async {
    if (!_isAndroid) return;
    final backend = _backend;
    final exactAllowed =
        await _safeBool(() => backend.canScheduleExactNotifications());
    if (!exactAllowed) {
      final opened = await _safeBool(
        () => backend.requestExactAlarmsPermission(),
        fallback: false,
      );
      if (opened) return;
    }
    await _safe(() => backend.openAppNotificationSettings());
  }

  /// 立即发一条通知，用来验证权限、通道和图标。用独立 ID，不覆盖已排程的提醒。
  static Future<DiaryReminderStatus> sendTestNotification() async {
    if (!_isAndroid) {
      return _status(issue: DiaryReminderIssue.unsupportedPlatform);
    }
    await initialize();
    final s = await loadSettings();
    try {
      await _backend.show(
        id: testNotificationId,
        title: '测试 · 写日记提醒',
        body: '看到这条说明通知权限、通道与图标都正常',
        payload: payload,
        notificationDetails: _notificationDetails(),
      );
      _logSelfCheck('test_notification_sent', s);
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '写日记提醒测试通知发送失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      return _status(
        settings: s,
        issue: DiaryReminderIssue.scheduleFailed,
        message: '测试通知发送失败，请查看运行日志',
      );
    }
    if (!s.enabled) return _status(settings: s);
    return ensureScheduled(force: true);
  }

  // ------------------------------------------------------------ 点击与冷启动

  /// 绑定点击处理。绑定瞬间会补发尚未消费的点击，
  /// 避免「initialize 早于 App State 绑定」时把点击丢掉。
  static void bindTapHandler(void Function() handler) {
    _onOpenDiary = handler;
    if (_pendingTap) {
      _pendingTap = false;
      handler();
    }
  }

  static void _handleResponse(NotificationResponse response) {
    if (response.payload != payload) return;
    final handler = _onOpenDiary;
    if (handler != null) {
      handler();
    } else {
      _pendingTap = true;
    }
  }

  /// 读取冷启动来源。只会执行一次。
  static Future<void> handleColdStartNavigation() async {
    if (!_isAndroid || _coldStartHandled) return;
    _coldStartHandled = true;
    await initialize();
    try {
      final details = await _backend.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        final response = details!.notificationResponse;
        if (response != null) _handleResponse(response);
      }
    } catch (error, stackTrace) {
      // 只记录，不抛出：冷启动导航失败不应该影响启动
      AppLogService.instance.warning(
        '读取写日记提醒启动动作失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  // ------------------------------------------------------------------ 内部

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

  /// 下一次触发时刻。留 5 秒余量，避免插件因为时间已过而抛参数错误。
  static tz.TZDateTime _nextInstance(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var next =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now.add(const Duration(seconds: 5)))) {
      next =
          tz.TZDateTime(tz.local, now.year, now.month, now.day + 1, hour, minute);
    }
    return next;
  }

  static Future<AndroidNotificationChannel?> _lookupChannel() async {
    final channels = await _safe(() => _backend.getChannels());
    if (channels == null) return null;
    for (final channel in channels) {
      if (channel.id == channelId) return channel;
    }
    return null;
  }

  /// 只读地判断当前有什么问题，不做任何排程动作。
  static Future<DiaryReminderIssue> _passiveIssue() async {
    if (!await _ensureIdentityLoaded()) {
      return DiaryReminderIssue.identityUnavailable;
    }
    if (_timezoneName == null) return DiaryReminderIssue.timezoneUnavailable;
    final backend = _backend;
    final exactAllowed =
        await _safeBool(() => backend.canScheduleExactNotifications());
    final notificationAllowed =
        await _safeBool(() => backend.areNotificationsEnabled(), fallback: true);
    return _issueFor(
      exactAllowed: exactAllowed,
      channel: await _lookupChannel(),
      notificationAllowed: notificationAllowed,
    );
  }

  static DiaryReminderIssue _issueFor({
    required bool exactAllowed,
    required AndroidNotificationChannel? channel,
    required bool notificationAllowed,
  }) {
    if (!notificationAllowed) return DiaryReminderIssue.notificationsDenied;
    if (channel != null && channel.importance == Importance.none) {
      return DiaryReminderIssue.channelDisabled;
    }
    if (!exactAllowed) return DiaryReminderIssue.exactAlarmDenied;
    return DiaryReminderIssue.none;
  }

  static String? _issueMessage(
    DiaryReminderIssue issue,
    Importance? importance,
  ) {
    switch (issue) {
      case DiaryReminderIssue.identityUnavailable:
        return '请先选择用户身份，再开启写日记提醒';
      case DiaryReminderIssue.timezoneUnavailable:
        return '系统时区读取失败，已暂停提醒（不会用 UTC 代替）。请检查系统时区后重试。';
      case DiaryReminderIssue.notificationsDenied:
        return '通知权限未授予，提醒不会显示。点按前往系统设置。';
      case DiaryReminderIssue.channelDisabled:
        return '「写日记提醒」通知通道已被关闭，提醒不会显示。点按前往系统设置。';
      case DiaryReminderIssue.exactAlarmDenied:
        return '缺少精确闹钟权限，提醒可能延迟几分钟。点按前往系统设置。';
      case DiaryReminderIssue.scheduleFailed:
        return '排程失败，请查看运行日志';
      case DiaryReminderIssue.statusUnavailable:
        return '读取提醒设置失败，请查看运行日志';
      case DiaryReminderIssue.unsupportedPlatform:
      case DiaryReminderIssue.none:
        // 通道重要性偏低不会让提醒消失，但可能不弹横幅、不出声
        if (importance != null && importance.value < Importance.high.value) {
          return '通知通道重要性偏低，可能不弹横幅或不出声';
        }
        return null;
    }
  }

  static String _fingerprint(DiaryReminderSettings s, bool exactAllowed) {
    return '${_key(_enabledBaseKey)}|${s.hour}|${s.minute}'
        '|${_timezoneName ?? ''}|$exactAllowed';
  }

  /// 排程日志：阶段名 + 关键字段。这是「下次再失效时能自己看出原因」的主要依据。
  static void _logSelfCheck(
    String stage,
    DiaryReminderSettings s, {
    DiaryReminderStatus? status,
    String? reason,
  }) {
    final effective = status ?? _status(settings: s);
    final buffer = StringBuffer('写日记提醒自检[$stage]: ')
      ..write('enabled=${s.enabled}, ')
      ..write('time=${s.timeLabel}, ')
      ..write('issue=${effective.issue.name}, ')
      ..write('pending=${effective.scheduled}, ')
      ..write('exact=${effective.exactAllowed}, ')
      ..write('notif=${effective.notificationAllowed}, ')
      ..write('channel=${effective.channelImportance ?? 'unknown'}, ')
      ..write('tz=${effective.timezoneName ?? 'unavailable'}, ')
      ..write('scope=${_key(_enabledBaseKey)}');
    if (effective.nextFireAt != null) {
      buffer.write(', next=${effective.nextFireAt}');
    }
    if (reason != null) buffer.write(', reason=$reason');
    AppLogService.instance.info(buffer.toString(), source: logSource);
  }

  static DiaryReminderStatus _status({
    DiaryReminderSettings? settings,
    DiaryReminderIssue? issue,
    String? message,
    bool scheduled = false,
    bool exactAllowed = false,
    bool notificationAllowed = true,
    int? channelImportance,
    DateTime? nextFireAt,
  }) {
    final effective = settings ?? const DiaryReminderSettings.defaults();
    final effectiveIssue = issue ?? DiaryReminderIssue.none;
    return DiaryReminderStatus(
      settings: effective,
      issue: effectiveIssue,
      message: message ?? _issueMessage(effectiveIssue, null),
      scheduled: scheduled,
      exactAllowed: exactAllowed,
      notificationAllowed: notificationAllowed,
      channelImportance: channelImportance,
      timezoneName: _timezoneName,
      nextFireAt: nextFireAt,
    );
  }

  static Future<bool> _ensureIdentityLoaded() async {
    if (!AppIdentityService.isLoaded) {
      try {
        await AppIdentityService.load();
      } catch (_) {
        // 读不到身份不影响判断：personKind 仍为 null，按未选身份处理
      }
    }
    return AppIdentityService.personKind != null;
  }

  /// 身份作用域下的偏好存储。
  ///
  /// 只在尚未加载时才 `load()`：`_loadInternal` 结尾会无条件通知变更，
  /// 在身份变更监听里再次 `load()` 会构成死循环。
  static Future<SharedPreferences> _prefs() async {
    await _ensureIdentityLoaded();
    return SharedPreferences.getInstance();
  }

  static String _key(String baseKey) =>
      AppIdentityService.dataKeyForCurrentIdentity(baseKey);

  static Future<T?> _safe<T>(Future<T?> Function() action) async {
    try {
      return await action();
    } catch (error, stackTrace) {
      AppLogService.instance.warning(
        '写日记提醒调用系统接口失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static Future<bool> _safeBool(
    Future<bool?> Function() action, {
    bool fallback = false,
  }) async {
    final value = await _safe(action);
    return value ?? fallback;
  }
}
