import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../models/daily_review_reminder.dart';
import '../screens/daily_review_screen.dart';
import 'daily_review_alarm.dart';
import 'daily_review_native.dart';
import 'daily_review_summary.dart';

typedef DailyReviewTapHandler = void Function(DateTime date);

class DailyReviewNotificationService {
  static const _prefEnabled = 'daily_review_enabled';
  static const _prefHour = 'daily_review_hour';
  static const _prefMinute = 'daily_review_minute';
  static const _notificationId = 1001;
  static const _alarmId = 1001;
  static const _channelId = 'daily_review_v2';
  static const _channelName = '每日复盘';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;
  static Future<void>? _ongoingSchedule;
  static GlobalKey<NavigatorState>? _navigatorKey;
  static DailyReviewTapHandler? _onTap;

  static AndroidFlutterLocalNotificationsPlugin? get _androidPlugin =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> initialize({
    GlobalKey<NavigatorState>? navigatorKey,
    DailyReviewTapHandler? onTap,
  }) async {
    _navigatorKey = navigatorKey;
    _onTap = onTap;

    if (_initialized) return;
    if (!_isAndroid) {
      _initialized = true;
      return;
    }

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
    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    const androidChannel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: '每日复盘提醒',
      importance: Importance.high,
    );

    await _androidPlugin?.createNotificationChannel(androidChannel);
  }

  static void _onNotificationResponse(NotificationResponse response) {
    final date = DailyReviewSummaryBuilder.dateFromPayload(response.payload);
    if (date != null) {
      _openReviewPage(date);
    }
  }

  /// App 冷启动时：通知点击 或 原生 Intent 带入的日期
  static Future<void> handleColdStartNavigation() async {
    if (!_isAndroid || !_initialized) return;

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final payload = launchDetails!.notificationResponse?.payload;
      final date = DailyReviewSummaryBuilder.dateFromPayload(payload);
      if (date != null) {
        _openReviewPage(date);
        return;
      }
    }

    final nativeDateKey = await DailyReviewNative.consumeLaunchReviewDate();
    if (nativeDateKey != null) {
      final parts = nativeDateKey.split('-');
      if (parts.length == 3) {
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);
        if (year != null && month != null && day != null) {
          _openReviewPage(DateTime(year, month, day));
        }
      }
    }
  }

  static void _openReviewPage(DateTime date) {
    final normalized = DateTime(date.year, date.month, date.day);
    final handler = _onTap;
    if (handler != null) {
      handler(normalized);
      return;
    }

    final navigator = _navigatorKey?.currentState;
    if (navigator != null) {
      DailyReviewScreen.open(navigator.context, date: normalized);
    }
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

  static Future<bool> showTestNotification() async {
    if (!_initialized) {
      await _initTimezoneAndPlugin();
      _initialized = true;
    }

    final today = DateTime.now();
    return _showReminderNotification(
      date: DateTime(today.year, today.month, today.day),
      aiReady: true,
      isTest: true,
    );
  }

  static Future<void> syncReminderIfEnabled() async {
    final settings = await loadSettings();
    if (!settings.enabled) return;
    await schedule(settings);
  }

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

  static Future<void> _registerNextReminder(DailyReviewReminder settings) async {
    try {
      if (_isAndroid) {
        await AndroidAlarmManager.cancel(_alarmId);
      }
      await _plugin.cancel(id: _notificationId);

      if (!settings.enabled) return;
      if (!_isAndroid) {
        debugPrint('当前平台不支持 AndroidAlarmManager，跳过后台闹钟注册');
        return;
      }

      if (!_initialized) {
        await _initTimezoneAndPlugin();
        _initialized = true;
      }

      final next = _nextInstance(settings.hour, settings.minute);
      final useExact = await canScheduleExactAlarms();
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
        '每日提醒已注册: $fireAt, exact=$useExact, ok=$scheduled',
      );
    } catch (e, st) {
      debugPrint('注册每日提醒失败: $e\n$st');
    }
  }

  /// 到点：生成 AI 复盘并发送简短提醒通知
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
      final date = DateTime(now.year, now.month, now.day);

      final result = await DailyReviewSummaryBuilder.fetchAiForDate(date);
      debugPrint('AI 复盘生成: success=${result.isSuccess}');

      await _showReminderNotification(
        date: date,
        aiReady: result.isSuccess,
      );

      await _registerNextReminder(settings);
    } catch (e, st) {
      debugPrint('每日提醒触发失败: $e\n$st');
    }
  }

  static Future<bool> _showReminderNotification({
    required DateTime date,
    required bool aiReady,
    bool isTest = false,
  }) async {
    final payload = DailyReviewSummaryBuilder.payloadForDate(date);
    final title = isTest ? '测试 · 今日复盘' : '今日复盘';
    final body = aiReady ? 'AI 总结已就绪，点击查看' : '生成失败，点击查看并重试';

    var shown = await DailyReviewNative.showNotification(
      title: title,
      body: body,
      dateKey: DailyReviewSummaryBuilder.dateKey(date),
    );
    if (shown) return true;

    try {
      await _plugin.show(
        id: _notificationId,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: '每日复盘提醒',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
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
    if (_isAndroid) {
      await AndroidAlarmManager.cancel(_alarmId);
    }
    await _plugin.cancel(id: _notificationId);
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
