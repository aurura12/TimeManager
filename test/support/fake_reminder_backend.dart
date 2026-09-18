import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:time_manager/services/reminder_backend.dart';
import 'package:timezone/timezone.dart' as tz;

/// 一次 `zonedSchedule` 调用的记录。
class FakeScheduledCall {
  const FakeScheduledCall({
    required this.id,
    required this.scheduledDate,
    required this.matchDateTimeComponents,
    required this.scheduleMode,
    required this.payload,
    required this.notificationDetails,
  });

  final int id;
  final tz.TZDateTime scheduledDate;
  final DateTimeComponents? matchDateTimeComponents;
  final AndroidScheduleMode scheduleMode;
  final String? payload;
  final AndroidNotificationDetails? notificationDetails;
}

/// 一次 `show` 调用的记录。
class FakeShownCall {
  const FakeShownCall({required this.id, required this.title, required this.payload});

  final int id;
  final String? title;
  final String? payload;
}

/// 手写 fake（项目没有 mockito）。
///
/// 刻意**不实现**删除通道的方法：服务层一旦尝试删除通道就会编译不过，
/// 这是「绝不 deleteNotificationChannel」的编译期保证。
class FakeReminderBackend implements ReminderBackend {
  int initializeCalls = 0;
  final List<AndroidNotificationChannel> createdChannels = [];
  final List<FakeScheduledCall> scheduledCalls = [];
  final List<FakeShownCall> shownCalls = [];
  final List<int> cancelledIds = [];
  final List<int> pendingQueries = [];
  final List<String> calls = <String>[];

  /// 可配置的返回值。
  bool? exactAllowed = true;
  bool? notificationsAllowed = true;
  bool throwOnSchedule = false;
  bool throwOnInitialize = false;
  List<AndroidNotificationChannel>? channels;
  List<PendingNotificationRequest> pending = <PendingNotificationRequest>[];
  NotificationAppLaunchDetails? launchDetails;
  bool? notificationPermissionResult = true;
  bool? openSettingsResult = true;

  @override
  Future<bool> initialize(
    AndroidInitializationSettings settings, {
    required void Function(NotificationResponse response) onResponse,
  }) async {
    initializeCalls++;
    calls.add('initialize');
    if (throwOnInitialize) throw StateError('initialize 失败');
    onResponseHandler = onResponse;
    return true;
  }

  /// 由测试触发点击回调。
  void Function(NotificationResponse response)? onResponseHandler;

  @override
  Future<void> createChannel(AndroidNotificationChannel channel) async {
    calls.add('createChannel');
    createdChannels.add(channel);
  }

  @override
  Future<List<AndroidNotificationChannel>?> getChannels() async {
    calls.add('getChannels');
    return channels;
  }

  @override
  Future<void> zonedSchedule({
    required int id,
    String? title,
    String? body,
    required tz.TZDateTime scheduledDate,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
    AndroidNotificationDetails? notificationDetails,
    AndroidScheduleMode scheduleMode = AndroidScheduleMode.exactAllowWhileIdle,
  }) async {
    calls.add('zonedSchedule');
    if (throwOnSchedule) throw StateError('排程失败');
    scheduledCalls.add(FakeScheduledCall(
      id: id,
      scheduledDate: scheduledDate,
      matchDateTimeComponents: matchDateTimeComponents,
      scheduleMode: scheduleMode,
      payload: payload,
      notificationDetails: notificationDetails,
    ));
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    AndroidNotificationDetails? notificationDetails,
    String? payload,
  }) async {
    calls.add('show');
    shownCalls.add(FakeShownCall(id: id, title: title, payload: payload));
  }

  @override
  Future<void> cancel({required int id}) async {
    calls.add('cancel');
    cancelledIds.add(id);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    calls.add('pendingNotificationRequests');
    pendingQueries.add(pendingQueries.length + 1);
    return pending;
  }

  @override
  Future<bool?> canScheduleExactNotifications() async {
    calls.add('canScheduleExactNotifications');
    return exactAllowed;
  }

  @override
  Future<bool?> areNotificationsEnabled() async {
    calls.add('areNotificationsEnabled');
    return notificationsAllowed;
  }

  @override
  Future<bool?> requestNotificationsPermission() async {
    calls.add('requestNotificationsPermission');
    return notificationPermissionResult;
  }

  @override
  Future<bool?> requestExactAlarmsPermission() async {
    calls.add('requestExactAlarmsPermission');
    return true;
  }

  @override
  Future<bool?> openAppNotificationSettings() async {
    calls.add('openAppNotificationSettings');
    return openSettingsResult;
  }

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async {
    calls.add('getNotificationAppLaunchDetails');
    return launchDetails;
  }

  /// 是否调用过任何周期性通知接口。服务层不应该出现这类调用。
  bool get usedPeriodicApi => calls.any(
        (name) =>
            name == 'periodicallyShow' || name == 'periodicallyShowWithDuration',
      );
}
