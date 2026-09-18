import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

/// 通知插件的薄封装。抽出接口是为了让服务层可以在不触碰原生通道的情况下被测试。
///
/// 写日记提醒与打卡目标提醒共用这一层：插件本身只有一份，两个提醒类型只是
/// 用不同的通知 ID、通道与 payload。
abstract class ReminderBackend {
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

class AndroidReminderBackend implements ReminderBackend {
  AndroidReminderBackend() : _plugin = FlutterLocalNotificationsPlugin();

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
