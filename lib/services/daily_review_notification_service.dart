import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../models/daily_review_reminder.dart';
import 'daily_review_alarm.dart';
import 'daily_review_native.dart';
import 'daily_review_summary.dart';

class DailyReviewNotificationService {
  static const _prefEnabled = 'daily_review_enabled';
  static const _prefHour = 'daily_review_hour';
  static const _prefMinute = 'daily_review_minute';
  /// 到点 AI 完成后展示的通知
  static const _displayNotificationId = 1001;
  /// 到点占位用的定时通知（与展示通知分开，避免注册次日任务时误删刚弹出的通知）
  static const _scheduledNotificationId = 1002;
  static const _alarmId = 1001;
  static const _channelId = 'daily_review_v2';
  static const _channelName = '每日复盘';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;
  static Future<void>? _ongoingSchedule;

  static AndroidFlutterLocalNotificationsPlugin? get _androidPlugin =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  static NotificationDetails get _notificationDetails => NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '每天根据记录生成当日复盘总结',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
        ),
      );

  static Future<void> initialize() async {
    if (_initialized) return;

    await _initTimezoneAndPlugin();
    _initialized = true;
    await DailyReviewNative.registerAlarmPlugins();

    try {
      await syncReminderIfEnabled();
    } catch (e, st) {
      debugPrint('恢复每日提醒失败（不影响 App 启动）: $e\n$st');
    }
  }

  static Future<void> _initTimezoneAndPlugin() async {
    tz_data.initializeTimeZones();
    try {
      final timeZoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneInfo.identifier));
    } catch (e) {
      debugPrint('时区初始化失败，使用 UTC: $e');
      tz.setLocalLocation(tz.UTC);
    }

    const androidSettings =
        AndroidInitializationSettings('@mipmap/launcher_icon');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings: initSettings);

    const androidChannel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: '每天根据记录生成当日复盘总结',
      importance: Importance.high,
    );

    await _androidPlugin?.createNotificationChannel(androidChannel);
  }

  static Future<DailyReviewReminder> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return DailyReviewReminder(
      enabled: prefs.getBool(_prefEnabled) ?? false,
      hour: prefs.getInt(_prefHour) ?? 22,
      minute: prefs.getInt(_prefMinute) ?? 0,
    );
  }

  static Future<void> saveSettings(DailyReviewReminder settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, settings.enabled);
    await prefs.setInt(_prefHour, settings.hour);
    await prefs.setInt(_prefMinute, settings.minute);

    if (settings.enabled) {
      await schedule(settings);
    } else {
      await cancel();
    }
  }

  static Future<bool> requestPermission() async {
    final androidPlugin = _androidPlugin;
    if (androidPlugin == null) return true;

    final notificationGranted =
        await androidPlugin.requestNotificationsPermission();
    final exactGranted = await androidPlugin.requestExactAlarmsPermission();

    final notificationsOk = notificationGranted ?? true;
    final exactOk = exactGranted ?? true;
    return notificationsOk && exactOk;
  }

  static Future<bool> canScheduleExactAlarms() async {
    final androidPlugin = _androidPlugin;
    if (androidPlugin == null) return true;
    return await androidPlugin.canScheduleExactNotifications() ?? true;
  }

  /// 立即发一条测试通知，用于确认通知渠道和权限正常
  static Future<bool> showTestNotification() async {
    if (!_initialized) {
      await _initTimezoneAndPlugin();
      _initialized = true;
    }

    const summary = DailyReviewSummary(
      title: '测试通知',
      body: '如果你看到这条消息，说明通知权限和渠道配置正常。',
    );
    return _showNotification(summary);
  }

  /// App 启动时恢复提醒；改时间/开关也只注册定时任务，不调用 AI
  static Future<void> syncReminderIfEnabled() async {
    final settings = await loadSettings();
    if (!settings.enabled) return;
    await schedule(settings);
  }

  /// 仅注册下一次提醒，不请求 AI
  static Future<void> schedule(DailyReviewReminder settings) async {
    final previous = _ongoingSchedule;
    final job = _registerNextReminder(settings);
    _ongoingSchedule = job;
    try {
      if (previous != null) await previous;
      await job;
    } finally {
      if (_ongoingSchedule == job) _ongoingSchedule = null;
    }
  }

  static Future<void> _registerNextReminder(
    DailyReviewReminder settings, {
    bool cancelVisibleNotification = true,
  }) async {
    try {
      await AndroidAlarmManager.cancel(_alarmId);
      await _plugin.cancel(id: _scheduledNotificationId);
      if (cancelVisibleNotification) {
        await _plugin.cancel(id: _displayNotificationId);
      }

      if (!settings.enabled) return;

      if (!_initialized) {
        await _initTimezoneAndPlugin();
        _initialized = true;
      }

      final next = _nextInstance(settings.hour, settings.minute);
      final useExact = await canScheduleExactAlarms();

      await _schedulePlaceholderNotification(next, useExact: useExact);

      final fireAt = DateTime(
        next.year,
        next.month,
        next.day,
        next.hour,
        next.minute,
      );

      final scheduled = await AndroidAlarmManager.oneShotAt(
        fireAt,
        _alarmId,
        dailyReviewAlarmCallback,
        allowWhileIdle: true,
        wakeup: true,
        exact: useExact,
        alarmClock: useExact,
        rescheduleOnReboot: true,
      );

      debugPrint(
        '每日提醒已注册: $fireAt, exact=$useExact, alarmClock=$useExact, ok=$scheduled',
      );
    } catch (e, st) {
      debugPrint('注册每日提醒失败: $e\n$st');
    }
  }

  static Future<void> _schedulePlaceholderNotification(
    tz.TZDateTime next, {
    required bool useExact,
  }) async {
    await _plugin.zonedSchedule(
      id: _scheduledNotificationId,
      title: '今日复盘',
      body: '正在生成今日总结，请稍候…',
      scheduledDate: next,
      notificationDetails: _notificationDetails,
      androidScheduleMode: useExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// 到点触发：此时才请求 AI（或本地兜底）并弹出通知
  static Future<void> onReminderFired() async {
    try {
      debugPrint('每日提醒到点触发');
      await DailyReviewNative.registerAlarmPlugins();

      if (!_initialized) {
        await _initTimezoneAndPlugin();
        _initialized = true;
      }

      final settings = await loadSettings();
      if (!settings.enabled) return;

      final now = tz.TZDateTime.now(tz.local);
      final summary = await DailyReviewSummaryBuilder.buildForDate(
        DateTime(now.year, now.month, now.day),
        allowNetworkAi: true,
      );

      final shown = await _showNotification(summary);
      debugPrint('每日提醒通知已展示: $shown');

      // 不要 cancel 刚展示的通知，只重新注册明天的定时任务
      await _registerNextReminder(
        settings,
        cancelVisibleNotification: false,
      );
    } catch (e, st) {
      debugPrint('每日提醒触发失败: $e\n$st');
    }
  }

  static Future<bool> _showNotification(DailyReviewSummary summary) async {
    // 后台 isolate 优先走原生通知，更可靠
    var shown = await DailyReviewNative.showNotification(
      title: summary.title,
      body: summary.body,
    );

    if (shown) return true;

    try {
      await _plugin.show(
        id: _displayNotificationId,
        title: summary.title,
        body: summary.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: '每天根据记录生成当日复盘总结',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
            styleInformation: BigTextStyleInformation(summary.body),
          ),
        ),
      );
      return true;
    } catch (e, st) {
      debugPrint('Flutter 通知展示失败: $e\n$st');
      return false;
    }
  }

  static Future<void> cancel() async {
    await AndroidAlarmManager.cancel(_alarmId);
    await _plugin.cancel(id: _displayNotificationId);
    await _plugin.cancel(id: _scheduledNotificationId);
  }

  static tz.TZDateTime _nextInstance(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}
