import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/time_block_reminder.dart';
import '../utils/time_block_reminder_plan.dart';
import 'app_identity_service.dart';
import 'app_log_service.dart';
import 'reminder_backend.dart';
import 'reminder_platform.dart';

/// 读取「今天 + 未来两天」的时间块快照。返回 null 表示数据尚未就绪。
typedef TimeBlockReminderScheduleSource = List<TimeBlockReminderDay>? Function();

enum TimeBlockReminderTrigger {
  startup,
  resume,
  scheduleChanged,
  identity,
  dayChange,
  settings,
  midnight,
  manual,
}

/// 时间块到点提醒：按当天已排好的事件块安排一次性通知。
///
/// 与写日记 / 打卡提醒的差别：
/// - 每天的时刻都不同，只能用一次性绝对时刻（matchDateTimeComponents 必须为 null）；
/// - 没有系统自续期，靠 reconcile 在编辑、回前台、跨日、身份切换后重新对齐；
/// - 通知 id 由「日期 + 块起点」推导，不做持久化分配表。
class TimeBlockReminderService {
  const TimeBlockReminderService._();

  static const int notificationIdMin = timeBlockReminderIdBase;
  static const int notificationIdMax = timeBlockReminderIdMax;

  /// 测试通知放在区间外，不参与原生归属判定，也不会覆盖真实排程。
  static const int testNotificationId = 2399;

  static const String channelId = 'time_block_reminder_v1';
  static const String channelName = '时间块提醒';
  static const String channelDescription = '事件开始时提醒';
  static const String smallIcon = 'ic_stat_time_block_reminder';
  static const String logSource = 'time_block_reminder';

  static const String _enabledBaseKey = 'time_block_reminder_enabled';
  static const String _leadBaseKey = 'time_block_reminder_lead_minutes';
  static const String _handledBaseKey = 'time_block_reminder_fired_v1';

  /// 已登记的通知 id：全局不分身份。id 段是全设备共享的，
  /// 换身份后必须能清掉上一位留下的排程。
  static const String _scheduledIdsKey = 'time_block_reminder_scheduled_ids_v1';

  /// 编辑后 800ms 合并一次；resume / 启动用 force 绕过。
  static const Duration _reconcileDebounce = Duration(milliseconds: 800);
  static const Duration _minReconcileInterval = Duration(seconds: 5);
  static const String _tapRouteKey = 'time_block_reminder';

  static bool _initialized = false;
  static Future<TimeBlockReminderStatus>? _initializationFuture;
  static TimeBlockReminderScheduleSource? _source;
  static DateTime? _lastReconcileAt;
  static TimeBlockReminderStatus? _lastStatus;
  /// 串行队列。刻意留空并在调用方所在的 Zone 里懒创建：
  /// 静态初始化的 Future 属于根 Zone，在 widget 测试的 FakeAsync 里不会被
  /// pump 推进，会让第一次 reconcile 一直挂起。
  static Future<void>? _queue;
  static Timer? _debounceTimer;
  static Map<String, TimeBlockReminderFiredRecord> _handled = {};
  static String? _handledScope;

  @visibleForTesting
  static DateTime Function()? clockOverride;

  @visibleForTesting
  static Map<String, TimeBlockReminderFiredRecord> get handledForTesting =>
      _handled;

  @visibleForTesting
  static void resetForTesting() {
    _initialized = false;
    _initializationFuture = null;
    _source = null;
    _lastReconcileAt = null;
    _lastStatus = null;
    _queue = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _handled = {};
    _handledScope = null;
    clockOverride = null;
  }

  static ReminderBackend get _backend => ReminderPlatform.backend;

  static bool get _isAndroid => ReminderPlatform.isAndroid;

  static String? get _timezoneName => ReminderPlatform.timezoneName;

  static DateTime _now() => clockOverride?.call() ?? DateTime.now();

  static Future<T?> _safe<T>(Future<T?> Function() action) =>
      ReminderPlatform.safe(action, source: logSource);

  static Future<bool> _safeBool(
    Future<bool?> Function() action, {
    bool fallback = false,
  }) =>
      ReminderPlatform.safeBool(action, fallback: fallback);

  // ---------------------------------------------------------------- 初始化

  static Future<TimeBlockReminderStatus> initialize() =>
      _initializationFuture ??= _initialize();

  static Future<TimeBlockReminderStatus> _initialize() async {
    if (!_isAndroid) {
      _initialized = true;
      return _status(issue: TimeBlockReminderIssue.unsupportedPlatform);
    }
    TimeBlockReminderStatus status;
    try {
      final pluginReady = await ReminderPlatform.ensureInitialized();
      if (!pluginReady) {
        _initialized = true;
        return _status(
          issue: TimeBlockReminderIssue.scheduleFailed,
          message: '提醒初始化失败，请查看运行日志',
        );
      }
      await _backend.createChannel(
        const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.high,
        ),
      );
      status = _status(settings: await _readSettingsSafe());
    } catch (error, stackTrace) {
      _initialized = true;
      AppLogService.instance.error(
        '时间块提醒初始化失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      return _status(
        issue: TimeBlockReminderIssue.scheduleFailed,
        message: '提醒初始化失败，请查看运行日志',
      );
    }
    _initialized = true;
    return status;
  }

  /// 由 main.dart 注入「读取 3 天槽位」的闭包，服务不反向依赖 TimeProvider。
  static void attachScheduleSource(TimeBlockReminderScheduleSource source) {
    _source = source;
  }

  // ------------------------------------------------------------ 设置读写

  static Future<TimeBlockReminderSettings> loadSettings() async {
    final prefs = await _prefs();
    final lead = prefs.getInt(_key(_leadBaseKey)) ??
        TimeBlockReminderSettings.defaultLeadMinutes;
    return TimeBlockReminderSettings(
      enabled: prefs.getBool(_key(_enabledBaseKey)) ?? false,
      leadMinutes: TimeBlockReminderSettings.isValidLead(lead)
          ? lead
          : TimeBlockReminderSettings.defaultLeadMinutes,
    );
  }

  static Future<TimeBlockReminderSettings> _readSettingsSafe() async {
    try {
      return await loadSettings();
    } catch (_) {
      return const TimeBlockReminderSettings.defaults();
    }
  }

  static Future<TimeBlockReminderStatus> saveSettings(
    TimeBlockReminderSettings next,
  ) async {
    final normalized = TimeBlockReminderSettings(
      enabled: next.enabled,
      leadMinutes: TimeBlockReminderSettings.isValidLead(next.leadMinutes)
          ? next.leadMinutes
          : TimeBlockReminderSettings.defaultLeadMinutes,
    );
    if (!_isAndroid) {
      return _status(
        settings: normalized,
        issue: TimeBlockReminderIssue.unsupportedPlatform,
      );
    }
    await initialize();

    if (!await _ensureIdentityLoaded()) {
      return _status(
        settings: normalized,
        issue: TimeBlockReminderIssue.identityUnavailable,
        message: '请先选择用户身份，再开启时间块提醒',
      );
    }

    final prefs = await _prefs();
    final enabledSaved = await prefs.setBool(_key(_enabledBaseKey), normalized.enabled);
    final leadSaved = await prefs.setInt(_key(_leadBaseKey), normalized.leadMinutes);
    if (!enabledSaved || !leadSaved) {
      // 回读磁盘旧值，让 UI 的开关自动回到真实状态。
      final disk = await _readSettingsSafe();
      return _status(
        settings: disk,
        issue: TimeBlockReminderIssue.saveFailed,
        message: '保存设置失败，请检查存储空间后重试',
      );
    }

    if (!normalized.enabled) {
      await _cancelAllInRange();
      _handled = {};
      await _saveHandled();
      return _status(settings: normalized, scheduledCount: 0);
    }
    return reconcile(force: true, trigger: TimeBlockReminderTrigger.settings);
  }

  static Future<TimeBlockReminderStatus> loadStatus() async {
    if (!_isAndroid) {
      return _status(issue: TimeBlockReminderIssue.unsupportedPlatform);
    }
    final init = await initialize();
    if (init.issue == TimeBlockReminderIssue.scheduleFailed) return init;

    final settings = await _readSettingsSafe();
    if (!await _ensureIdentityLoaded()) {
      // 未选身份时开关必须置灰：否则会写进 identity_unbound_*，选完身份后设置凭空消失。
      return _status(
        settings: settings,
        issue: TimeBlockReminderIssue.identityUnavailable,
        message: '请先选择用户身份，再开启时间块提醒',
      );
    }
    if (!settings.enabled) {
      final backend = _backend;
      final exactAllowed =
          await _safeBool(() => backend.canScheduleExactNotifications());
      final notificationAllowed =
          await _safeBool(() => backend.areNotificationsEnabled(), fallback: true);
      final channel = await _lookupChannel();
      final issue = _issueFor(
        exactAllowed: exactAllowed,
        channel: channel,
        notificationAllowed: notificationAllowed,
      );
      return _status(
        settings: settings,
        issue: issue,
        scheduledCount: 0,
        exactAllowed: exactAllowed,
        notificationAllowed: notificationAllowed,
        channelImportance: channel?.importance.value,
      );
    }
    return reconcile(force: true, trigger: TimeBlockReminderTrigger.manual);
  }

  // -------------------------------------------------------------- 排程

  /// 串行执行，避免回前台与编辑防抖同时触发时互相覆盖计划。
  static Future<TimeBlockReminderStatus> reconcile({
    bool force = false,
    TimeBlockReminderTrigger trigger = TimeBlockReminderTrigger.manual,
  }) {
    final completer = Completer<TimeBlockReminderStatus>();
    final previous = _queue ?? Future<void>.value();
    _queue = previous.then((_) async {
      try {
        completer.complete(await _reconcile(force: force, trigger: trigger));
      } catch (error, stackTrace) {
        AppLogService.instance.error(
          '时间块提醒排程失败',
          source: logSource,
          error: error,
          stackTrace: stackTrace,
        );
        completer.complete(
          _status(
            issue: TimeBlockReminderIssue.scheduleFailed,
            message: '排程失败，请查看运行日志',
          ),
        );
      }
    });
    return completer.future;
  }

  /// 编辑落盘后的合并入口（fire-and-forget）。
  static void requestReconcile() {
    if (!_isAndroid || !_initialized) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_reconcileDebounce, () {
      unawaited(
        reconcile(
          force: true,
          trigger: TimeBlockReminderTrigger.scheduleChanged,
        ),
      );
    });
  }

  static Future<TimeBlockReminderStatus> _reconcile({
    required bool force,
    required TimeBlockReminderTrigger trigger,
  }) async {
    if (!_isAndroid) {
      return _lastStatus = _status(issue: TimeBlockReminderIssue.unsupportedPlatform);
    }
    if (!_initialized) {
      return _lastStatus = _status();
    }

    final now = _now();
    final last = _lastReconcileAt;
    if (!force && last != null && now.difference(last) < _minReconcileInterval) {
      return _lastStatus ?? _status(settings: await _readSettingsSafe());
    }
    _lastReconcileAt = now;

    final settings = await _readSettingsSafe();
    if (!await _ensureIdentityLoaded()) {
      // id 段是全设备共用的：上一个身份留下的排程必须清掉，
      // 但设置绝不写进 identity_unbound_*。
      await _cancelAllInRange();
      _handled = {};
      _handledScope = null;
      return _lastStatus = _status(
        settings: settings,
        issue: TimeBlockReminderIssue.identityUnavailable,
        message: '请先选择用户身份，再开启时间块提醒',
      );
    }
    await _loadHandled();

    if (!settings.enabled) {
      await _cancelAllInRange();
      _handled = {};
      await _saveHandled();
      final status = _status(
        settings: settings,
        scheduledCount: 0,
        message: '提醒已关闭',
      );
      _logSelfCheck('cancelled', status, reason: 'disabled');
      return _lastStatus = status;
    }

    final source = _source;
    final days = source?.call();
    if (source == null || days == null) {
      // 数据没就绪时保留现有排程，绝不能因为读不到数据就全部取消。
      return _lastStatus = _status(
        settings: settings,
        issue: TimeBlockReminderIssue.sourceUnavailable,
        message: '时间块数据尚未就绪，已保留现有提醒',
      );
    }

    if (_timezoneName == null) {
      return _lastStatus = _status(
        settings: settings,
        issue: TimeBlockReminderIssue.timezoneUnavailable,
        message: '系统时区读取失败，已暂停提醒（不会用 UTC 代替）。请检查系统时区后重试。',
      );
    }

    final backend = _backend;
    final exactAllowed =
        await _safeBool(() => backend.canScheduleExactNotifications());
    final notificationAllowed =
        await _safeBool(() => backend.areNotificationsEnabled(), fallback: true);
    if (!notificationAllowed) {
      await _cancelAllInRange();
      return _lastStatus = _status(
        settings: settings,
        issue: TimeBlockReminderIssue.notificationsDenied,
        message: '通知权限未授予，提醒无法显示。点按前往系统设置。',
        exactAllowed: exactAllowed,
      );
    }

    final pending = await _safe(() => backend.pendingNotificationRequests());
    final pendingIds = timeBlockReminderIdsInRange(
      (pending ?? const <PendingNotificationRequest>[]).map((item) => item.id),
    );
    final knownIds = timeBlockReminderIdsInRange(await _loadScheduledIds());

    final plan = buildTimeBlockReminderPlan(
      days: days,
      leadMinutes: settings.leadMinutes,
      now: now,
      handled: _handled,
      pendingIds: pendingIds,
      knownIds: knownIds,
    );

    // 先取消再登记：同一个 id 可能因为块被移动而需要换内容。
    for (final id in plan.staleIds) {
      await _safe(() => backend.cancel(id: id));
    }

    var failed = false;
    for (final item in plan.toSchedule) {
      try {
        if (item.catchUp) {
          // 事件已经开始：直接弹出，不再等闹钟。
          await backend.show(
            id: item.id,
            title: item.title,
            body: item.body,
            payload: _payloadFor(item.occurrence),
            notificationDetails: _notificationDetails(),
          );
        } else {
          await backend.zonedSchedule(
            id: item.id,
            title: item.title,
            body: item.body,
            scheduledDate: tz.TZDateTime.from(item.fireAt, tz.local),
            payload: _payloadFor(item.occurrence),
            // 一次性绝对时刻：非空会被原生改写成「今天/明天 + 时分」。
            matchDateTimeComponents: null,
            notificationDetails: _notificationDetails(),
            scheduleMode: exactAllowed
                ? AndroidScheduleMode.exactAllowWhileIdle
                : AndroidScheduleMode.inexactAllowWhileIdle,
          );
        }
      } catch (error, stackTrace) {
        failed = true;
        AppLogService.instance.error(
          '时间块提醒登记失败',
          source: logSource,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    _handled = plan.handled;
    await _saveHandled();
    await _saveScheduledIds(plan.desiredIds);

    final channel = await _lookupChannel();
    var issue = exactAllowed
        ? TimeBlockReminderIssue.none
        : TimeBlockReminderIssue.exactAlarmDenied;
    if (channel != null && channel.importance == Importance.none) {
      issue = TimeBlockReminderIssue.channelDisabled;
    }
    if (failed) issue = TimeBlockReminderIssue.scheduleFailed;

    final status = _status(
      settings: settings,
      issue: issue,
      message: _issueMessage(issue, channel?.importance),
      scheduledCount: plan.scheduledCount,
      nextFireAt: plan.nextFireAt,
      exactAllowed: exactAllowed,
      notificationAllowed: notificationAllowed,
      channelImportance: channel?.importance.value,
    );
    _logSelfCheck('reconciled', status, plan: plan, reason: trigger.name);
    return _lastStatus = status;
  }

  // ------------------------------------------------------------ 权限与自检

  static Future<TimeBlockReminderStatus> requestPermissions() async {
    if (!_isAndroid) {
      return _status(issue: TimeBlockReminderIssue.unsupportedPlatform);
    }
    await initialize();
    final backend = _backend;
    await _safe(() => backend.requestNotificationsPermission());
    if (!await _safeBool(() => backend.canScheduleExactNotifications())) {
      await _safe(() => backend.requestExactAlarmsPermission());
    }
    final settings = await _readSettingsSafe();
    if (!settings.enabled) return _status(settings: settings);
    return reconcile(force: true, trigger: TimeBlockReminderTrigger.manual);
  }

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

  static Future<TimeBlockReminderStatus> sendTestNotification() async {
    if (!_isAndroid) {
      return _status(issue: TimeBlockReminderIssue.unsupportedPlatform);
    }
    await initialize();
    final settings = await _readSettingsSafe();
    try {
      await _backend.show(
        id: testNotificationId,
        title: '测试 · 时间块提醒',
        body: '看到这条说明通知权限、通道与图标都正常',
        notificationDetails: _notificationDetails(),
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '时间块提醒测试通知发送失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      return _status(
        settings: settings,
        issue: TimeBlockReminderIssue.scheduleFailed,
        message: '测试通知发送失败，请查看运行日志',
      );
    }
    return _status(settings: settings);
  }

  /// 点击处理。绑定瞬间会补发尚未消费的点击。
  static void bindTapHandler(void Function(TimeBlockReminderTap tap) handler) {
    ReminderPlatform.registerTapHandler(
      _tapRouteKey,
      matches: (value) => TimeBlockReminderTap.tryParse(value) != null,
      handler: (value) {
        final tap = TimeBlockReminderTap.tryParse(value);
        if (tap != null) handler(tap);
      },
    );
  }

  // ------------------------------------------------------------------ 内部

  static String _payloadFor(TimeBlockOccurrence occurrence) =>
      '${TimeBlockReminderTap.payloadPrefix}'
      '${occurrence.dateKey}:${occurrence.startIndex}';

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
      channelAction: AndroidNotificationChannelAction.createIfNotExists,
    );
  }

  static Future<AndroidNotificationChannel?> _lookupChannel() async {
    final channels = await _safe(() => _backend.getChannels());
    if (channels == null) return null;
    for (final channel in channels) {
      if (channel.id == channelId) return channel;
    }
    return null;
  }

  static TimeBlockReminderIssue _issueFor({
    required bool exactAllowed,
    required AndroidNotificationChannel? channel,
    required bool notificationAllowed,
  }) {
    if (!notificationAllowed) return TimeBlockReminderIssue.notificationsDenied;
    if (channel != null && channel.importance == Importance.none) {
      return TimeBlockReminderIssue.channelDisabled;
    }
    if (!exactAllowed) return TimeBlockReminderIssue.exactAlarmDenied;
    return TimeBlockReminderIssue.none;
  }

  static String? _issueMessage(
    TimeBlockReminderIssue issue,
    Importance? importance,
  ) {
    switch (issue) {
      case TimeBlockReminderIssue.identityUnavailable:
        return '请先选择用户身份，再开启时间块提醒';
      case TimeBlockReminderIssue.timezoneUnavailable:
        return '系统时区读取失败，已暂停提醒（不会用 UTC 代替）。请检查系统时区后重试。';
      case TimeBlockReminderIssue.notificationsDenied:
        return '通知权限未授予，提醒不会显示。点按前往系统设置。';
      case TimeBlockReminderIssue.channelDisabled:
        return '「时间块提醒」通知通道已被关闭，提醒不会显示。点按前往系统设置。';
      case TimeBlockReminderIssue.exactAlarmDenied:
        return '缺少精确闹钟权限，提醒可能延迟几分钟。点按前往系统设置。';
      case TimeBlockReminderIssue.scheduleFailed:
        return '排程失败，请查看运行日志';
      case TimeBlockReminderIssue.saveFailed:
        return '保存设置失败，请检查存储空间后重试';
      case TimeBlockReminderIssue.statusUnavailable:
        return '读取提醒设置失败，请查看运行日志';
      case TimeBlockReminderIssue.sourceUnavailable:
        return '时间块数据尚未就绪，已保留现有提醒';
      case TimeBlockReminderIssue.unsupportedPlatform:
      case TimeBlockReminderIssue.none:
        if (importance != null && importance.value < Importance.high.value) {
          return '通知通道重要性偏低，可能不弹横幅或不出声';
        }
        return null;
    }
  }

  static TimeBlockReminderStatus _status({
    TimeBlockReminderSettings? settings,
    TimeBlockReminderIssue? issue,
    String? message,
    int scheduledCount = 0,
    DateTime? nextFireAt,
    bool exactAllowed = false,
    bool notificationAllowed = true,
    int? channelImportance,
  }) {
    final effectiveIssue = issue ?? TimeBlockReminderIssue.none;
    return TimeBlockReminderStatus(
      settings: settings ?? const TimeBlockReminderSettings.defaults(),
      issue: effectiveIssue,
      message: message ?? _issueMessage(effectiveIssue, null),
      scheduledCount: scheduledCount,
      nextFireAt: nextFireAt,
      exactAllowed: exactAllowed,
      notificationAllowed: notificationAllowed,
      channelImportance: channelImportance,
      timezoneName: _timezoneName,
    );
  }

  static void _logSelfCheck(
    String stage,
    TimeBlockReminderStatus status, {
    TimeBlockReminderPlan? plan,
    String? reason,
  }) {
    final buffer = StringBuffer('时间块提醒自检[$stage]: ')
      ..write('enabled=${status.settings.enabled}, ')
      ..write('lead=${status.settings.leadMinutes}, ')
      ..write('issue=${status.issue.name}, ')
      ..write('planned=${status.scheduledCount}, ')
      ..write('exact=${status.exactAllowed}, ')
      ..write('notif=${status.notificationAllowed}, ')
      ..write('channel=${status.channelImportance ?? 'unknown'}, ')
      ..write('tz=${status.timezoneName ?? 'unavailable'}');
    if (plan != null) {
      buffer
        ..write(', toSchedule=${plan.toSchedule.length}')
        ..write(', stale=${plan.staleIds.length}')
        ..write(', catchUp=${plan.catchUpCount}')
        ..write(', ended=${plan.endedCount}');
    }
    if (status.nextFireAt != null) buffer.write(', next=${status.nextFireAt}');
    if (reason != null) buffer.write(', reason=$reason');
    AppLogService.instance.info(buffer.toString(), source: logSource);
  }

  static Future<void> _cancelAllInRange() async {
    final pending = await _safe(() => _backend.pendingNotificationRequests());
    final ids = <int>{
      ...timeBlockReminderIdsInRange(
        (pending ?? const <PendingNotificationRequest>[]).map((item) => item.id),
      ),
      ...timeBlockReminderIdsInRange(await _loadScheduledIds()),
    };
    for (final id in ids) {
      await _safe(() => _backend.cancel(id: id));
    }
    await _saveScheduledIds(const <int>{});
  }

  // ------------------------------------------------------------ 持久化

  static Future<void> _loadHandled() async {
    final scope = _key(_handledBaseKey);
    if (_handledScope == scope) return;
    final prefs = await _prefs();
    _handled = _decodeHandled(prefs.getString(scope));
    _handledScope = scope;
  }

  static Future<void> _saveHandled() async {
    if (_handledScope == null) return;
    final prefs = await _prefs();
    await prefs.setString(_key(_handledBaseKey), _encodeHandled(_handled));
  }

  static Map<String, TimeBlockReminderFiredRecord> _decodeHandled(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, TimeBlockReminderFiredRecord>{};
      for (final entry in decoded.entries) {
        final dateKey = entry.key;
        final value = entry.value;
        if (dateKey is! String || value is! Map) continue;
        for (final item in value.entries) {
          final index = int.tryParse('${item.key}');
          final record = TimeBlockReminderFiredRecord.tryParse(item.value);
          if (index == null || record == null) continue;
          result[timeBlockReminderOccurrenceKey(dateKey, index)] = record;
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static String _encodeHandled(Map<String, TimeBlockReminderFiredRecord> data) {
    final grouped = <String, Map<String, dynamic>>{};
    for (final entry in data.entries) {
      final separator = entry.key.indexOf('#');
      if (separator <= 0) continue;
      final dateKey = entry.key.substring(0, separator);
      final index = entry.key.substring(separator + 1);
      grouped.putIfAbsent(dateKey, () => <String, dynamic>{})[index] =
          entry.value.toJson();
    }
    return jsonEncode(grouped);
  }

  static Future<Set<int>> _loadScheduledIds() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_scheduledIdsKey);
    if (raw == null || raw.isEmpty) return <int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <int>{};
      return decoded.whereType<int>().toSet();
    } catch (_) {
      return <int>{};
    }
  }

  static Future<void> _saveScheduledIds(Set<int> ids) async {
    final prefs = await _prefs();
    final sorted = ids.toList()..sort();
    await prefs.setString(_scheduledIdsKey, jsonEncode(sorted));
  }

  static Future<bool> _ensureIdentityLoaded() async {
    if (!AppIdentityService.isLoaded) {
      try {
        await AppIdentityService.load();
      } catch (_) {
        // 读不到身份就按未选身份处理
      }
    }
    return AppIdentityService.personKind != null;
  }

  static Future<SharedPreferences> _prefs() async {
    await _ensureIdentityLoaded();
    final prefs = await SharedPreferences.getInstance();
    return prefs;
  }

  static String _key(String baseKey) =>
      AppIdentityService.dataKeyForCurrentIdentity(baseKey);
}
