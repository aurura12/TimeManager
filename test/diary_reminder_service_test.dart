import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/diary_reminder.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/diary_reminder_service.dart';
import 'package:time_manager/services/reminder_platform.dart';

import 'support/fake_reminder_backend.dart';

const MethodChannel _secureStorage =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// `DiaryReminderService` 的行为约定。
///
/// 重点不在「能排程」，而在这几条历史上真实踩过的坑不会被重新踩进去：
/// 不自建续订链、时区失败不静默回退 UTC、降级不用同样需要权限的 exactAllowWhileIdle、
/// 身份未选时不写进 unbound 作用域。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeReminderBackend backend;

  const enabled = DiaryReminderSettings(enabled: true, hour: 21, minute: 0);
  const disabled = DiaryReminderSettings(enabled: false, hour: 21, minute: 0);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    DiaryReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
    AppIdentityService.resetForTesting();

    backend = FakeReminderBackend();
    ReminderPlatform.backendOverride = backend;
    ReminderPlatform.androidPlatformOverride = true;
    ReminderPlatform.timezoneIdentifierOverride = () async => 'Asia/Shanghai';
    AppIdentityService.adoptManualKind(DiaryKind.g);
  });

  tearDown(() {
    DiaryReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorage, null);
  });

  group('设置读写', () {
    test('默认是关闭 + 21:00，读取设置不触碰原生接口', () async {
      final settings = await DiaryReminderService.loadSettings();
      expect(settings.enabled, isFalse);
      expect(settings.hour, 21);
      expect(settings.minute, 0);
      expect(settings.timeLabel, '21:00');
      expect(backend.calls, isEmpty);
    });

    test('时间展示为两位补零的 HH:mm', () {
      expect(
        const DiaryReminderSettings(enabled: true, hour: 9, minute: 5).timeLabel,
        '09:05',
      );
    });
  });

  group('排程', () {
    test('开启后只登记一次每日重复，用 exactAllowWhileIdle', () async {
      final status = await DiaryReminderService.saveSettings(enabled);

      expect(backend.scheduledCalls, hasLength(1));
      final call = backend.scheduledCalls.single;
      expect(call.id, DiaryReminderService.notificationId);
      // 关键：重复交给系统，不做链式续订
      expect(call.matchDateTimeComponents, DateTimeComponents.time);
      expect(call.scheduleMode, AndroidScheduleMode.exactAllowWhileIdle);
      expect(call.scheduledDate.hour, 21);
      expect(call.scheduledDate.minute, 0);
      expect(call.payload, DiaryReminderService.payload);
      expect(call.notificationDetails?.channelId,
          DiaryReminderService.channelId);
      expect(call.notificationDetails?.icon, DiaryReminderService.smallIcon);

      expect(status.scheduled, isTrue);
      expect(status.issue, DiaryReminderIssue.none);
    });

    test('不使用任何周期性通知接口，也不会再次登记', () async {
      await DiaryReminderService.saveSettings(enabled);
      expect(backend.usedPeriodicApi, isFalse);

      // pending 里已经有本提醒、指纹也没变 → 不应该重复登记
      backend.pending = <PendingNotificationRequest>[
        const PendingNotificationRequest(
          DiaryReminderService.notificationId,
          null,
          null,
          DiaryReminderService.payload,
        ),
      ];
      backend.scheduledCalls.clear();

      await DiaryReminderService.ensureScheduled(force: true);
      await DiaryReminderService.ensureScheduled(force: true);

      expect(backend.scheduledCalls, isEmpty);
      expect(backend.usedPeriodicApi, isFalse);
    });

    test('排定被系统清掉后，自检会重新登记', () async {
      await DiaryReminderService.saveSettings(enabled);
      backend.scheduledCalls.clear();
      backend.pending = <PendingNotificationRequest>[];

      final status = await DiaryReminderService.ensureScheduled(force: true);

      expect(backend.scheduledCalls, hasLength(1));
      expect(status.scheduled, isTrue);
    });

    test('关闭时取消同 ID 排定，不留下孤儿通知', () async {
      await DiaryReminderService.saveSettings(enabled);
      backend.cancelledIds.clear();

      final status = await DiaryReminderService.saveSettings(disabled);

      expect(backend.cancelledIds, contains(DiaryReminderService.notificationId));
      expect(status.settings.enabled, isFalse);
      expect(status.scheduled, isFalse);
    });

    test('排程抛异常时上报 scheduleFailed，不假装成功', () async {
      backend.throwOnSchedule = true;

      final status = await DiaryReminderService.saveSettings(enabled);

      expect(status.issue, DiaryReminderIssue.scheduleFailed);
      expect(status.scheduled, isFalse);
      expect(status.message, isNotNull);
    });

    test('并发 initialize 只初始化一次插件', () async {
      await Future.wait(<Future<DiaryReminderStatus>>[
        DiaryReminderService.initialize(),
        DiaryReminderService.initialize(),
      ]);

      expect(backend.initializeCalls, 1);
      expect(backend.createdChannels, hasLength(1));
      expect(backend.createdChannels.single.id, DiaryReminderService.channelId);
      expect(
        backend.createdChannels.single.importance,
        Importance.high,
        reason: '通道必须以高重要性创建，否则不会弹横幅',
      );
    });

    test('通道以 createIfNotExists 语义创建，从不删除', () async {
      await DiaryReminderService.initialize();

      // fake 没有实现任何 deleteNotificationChannel，服务一旦尝试删除就编译不过
      expect(backend.createdChannels, hasLength(1));
      expect(
        backend.calls.where((name) => name.contains('delete')),
        isEmpty,
      );
    });
  });

  group('时区', () {
    test('拿不到时区时拒绝排程，不静默回退 UTC', () async {
      ReminderPlatform.timezoneIdentifierOverride =
          () async => throw StateError('模拟读取时区失败');

      final status = await DiaryReminderService.saveSettings(enabled);

      expect(status.issue, DiaryReminderIssue.timezoneUnavailable);
      expect(status.timezoneName, isNull);
      expect(
        backend.scheduledCalls,
        isEmpty,
        reason: '没有可信时区就不排程，否则提醒会在错误的时间响',
      );
    });

    test('时区标识不是 IANA 名称时同样拒绝排程', () async {
      ReminderPlatform.timezoneIdentifierOverride = () async => 'GMT+08:00';

      final status = await DiaryReminderService.saveSettings(enabled);

      expect(status.issue, DiaryReminderIssue.timezoneUnavailable);
      expect(backend.scheduledCalls, isEmpty);
    });

    test('时区可用时记录在状态里', () async {
      final status = await DiaryReminderService.saveSettings(enabled);
      expect(status.timezoneName, 'Asia/Shanghai');
    });
  });

  group('权限降级', () {
    test('缺少精确闹钟权限时降级为 inexactAllowWhileIdle 并标记', () async {
      backend.exactAllowed = false;

      final status = await DiaryReminderService.saveSettings(enabled);

      expect(
        backend.scheduledCalls.single.scheduleMode,
        AndroidScheduleMode.inexactAllowWhileIdle,
        reason: 'exactAllowWhileIdle 同样需要精确闹钟权限，用它等于没有降级',
      );
      expect(status.issue, DiaryReminderIssue.exactAlarmDenied);
      expect(status.exactAllowed, isFalse);
    });

    test('通知权限未授予时不排程，并明确上报', () async {
      backend.notificationsAllowed = false;

      final status = await DiaryReminderService.saveSettings(enabled);

      expect(status.issue, DiaryReminderIssue.notificationsDenied);
      expect(backend.scheduledCalls, isEmpty);
      expect(status.message, isNotNull);
    });

    test('通道被用户关闭时上报 channelDisabled，但排程照旧', () async {
      backend.channels = <AndroidNotificationChannel>[
        const AndroidNotificationChannel(
          DiaryReminderService.channelId,
          '写日记提醒',
          importance: Importance.none,
        ),
      ];

      final status = await DiaryReminderService.saveSettings(enabled);

      expect(status.issue, DiaryReminderIssue.channelDisabled);
      expect(status.scheduled, isTrue);
      expect(status.channelImportance, Importance.none.value);
    });
  });

  group('身份', () {
    test('未选身份时不允许开启，且不写进任何作用域', () async {
      AppIdentityService.resetForTesting();

      final status = await DiaryReminderService.saveSettings(enabled);

      expect(status.issue, DiaryReminderIssue.identityUnavailable);
      expect(backend.scheduledCalls, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('identity_unbound_diary_reminder_enabled'), isNull);
      expect(prefs.getBool('identity_g_diary_reminder_enabled'), isNull);
      expect(prefs.getBool('identity_j_diary_reminder_enabled'), isNull);
    });

    test('设置按身份隔离，两个人各存一份', () async {
      await DiaryReminderService.saveSettings(enabled);

      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('identity_g_diary_reminder_enabled'), isTrue);
      expect(prefs.getInt('identity_g_diary_reminder_hour'), 21);

      // 切到另一个人：读到的是自己的（尚未设置）默认值
      AppIdentityService.adoptManualKind(DiaryKind.j);
      final other = await DiaryReminderService.loadSettings();
      expect(other.enabled, isFalse);
      expect(other.timeLabel, '21:00');

      // 另一个人开启后，两人的 key 互不影响
      await DiaryReminderService.saveSettings(
        const DiaryReminderSettings(enabled: true, hour: 8, minute: 30),
      );
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('identity_j_diary_reminder_hour'), 8);
      expect(prefs.getInt('identity_g_diary_reminder_hour'), 21);
    });
  });

  group('点击与冷启动', () {
    test('点击回调在绑定之前到达时会补发，不会丢', () async {
      await DiaryReminderService.initialize();
      var taps = 0;

      backend.onResponseHandler!(
        const NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotification,
          payload: DiaryReminderService.payload,
        ),
      );
      expect(taps, 0, reason: '此时还没有绑定处理函数');

      DiaryReminderService.bindTapHandler(() => taps++);
      expect(taps, 1);
    });

    test('不相干 payload 的点击不会触发导航', () async {
      await DiaryReminderService.initialize();
      var taps = 0;
      DiaryReminderService.bindTapHandler(() => taps++);

      backend.onResponseHandler!(
        const NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotification,
          payload: 'something-else',
        ),
      );

      expect(taps, 0);
    });

    test('冷启动导航只执行一次', () async {
      var taps = 0;
      DiaryReminderService.bindTapHandler(() => taps++);
      backend.launchDetails = const NotificationAppLaunchDetails(
        true,
        notificationResponse: NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotification,
          payload: DiaryReminderService.payload,
        ),
      );

      await ReminderPlatform.handleColdStartNavigation();
      await ReminderPlatform.handleColdStartNavigation();

      expect(taps, 1);
    });

    test('非通知冷启动不触发导航', () async {
      var taps = 0;
      DiaryReminderService.bindTapHandler(() => taps++);
      backend.launchDetails = const NotificationAppLaunchDetails(false);

      await ReminderPlatform.handleColdStartNavigation();

      expect(taps, 0);
    });
  });

  group('测试通知', () {
    test('用独立 ID 发送，不覆盖已排程的提醒', () async {
      await DiaryReminderService.saveSettings(enabled);

      await DiaryReminderService.sendTestNotification();

      expect(backend.shownCalls, hasLength(1));
      expect(backend.shownCalls.single.id, DiaryReminderService.testNotificationId);
      expect(
        backend.shownCalls.single.id,
        isNot(DiaryReminderService.notificationId),
      );
    });
  });

  group('非 Android 平台', () {
    test('桌面端整体短路，不触碰任何原生接口', () async {
      ReminderPlatform.androidPlatformOverride = false;
      backend.calls.clear();

      final status = await DiaryReminderService.loadStatus();

      expect(status.issue, DiaryReminderIssue.unsupportedPlatform);
      expect(backend.calls, isEmpty);
    });
  });
}
