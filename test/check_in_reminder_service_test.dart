import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/check_in_reminder.dart';
import 'package:time_manager/services/check_in_reminder_service.dart';
import 'package:time_manager/services/reminder_platform.dart';

import 'support/fake_reminder_backend.dart';

/// 打卡提醒的行为约定。与写日记提醒共用同一套硬约束，额外验证「多实例」：
/// 每个目标一个稳定的通知 id、互不干扰、目标消失后提醒要被清掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeReminderBackend backend;

  CheckInGoal goal(
    String id, {
    String name = '早睡',
    DateTime? startDate,
    DateTime? endDate,
    bool isArchived = false,
  }) {
    return CheckInGoal(
      id: id,
      ownerId: 'manual-g',
      ownerEmail: 'guai@example.com',
      name: name,
      description: '',
      color: const Color(0xFF96B462),
      icon: Icons.bedtime,
      period: CheckInPeriod.daily,
      targetCount: 1,
      startDate: startDate,
      endDate: endDate,
      isArchived: isArchived,
    );
  }

  CheckInReminderSettings settings(
    String goalId, {
    bool enabled = true,
    int hour = 21,
    int minute = 0,
    String name = '早睡',
  }) {
    return CheckInReminderSettings(
      goalId: goalId,
      enabled: enabled,
      hour: hour,
      minute: minute,
      goalName: name,
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CheckInReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();

    backend = FakeReminderBackend();
    ReminderPlatform.backendOverride = backend;
    ReminderPlatform.androidPlatformOverride = true;
    ReminderPlatform.timezoneIdentifierOverride = () async => 'Asia/Shanghai';
  });

  tearDown(() {
    CheckInReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
  });

  group('设置读写', () {
    test('默认是关闭 + 21:00，且不触碰原生接口', () async {
      final loaded = await CheckInReminderService.loadSettings('g1');

      expect(loaded.enabled, isFalse);
      expect(loaded.timeLabel, '21:00');
      expect(backend.calls, isEmpty);
    });

    test('保存开启会分配 2200 段的通知 id 并登记每日重复', () async {
      final result = await CheckInReminderService.saveSettings(
        settings('g1', hour: 8, minute: 30),
      );

      expect(result.ok, isTrue);
      expect(backend.scheduledCalls, hasLength(1));
      final call = backend.scheduledCalls.single;
      expect(call.id, inInclusiveRange(2200, 2299));
      expect(call.id, isNot(2001), reason: '不能和写日记提醒撞号');
      expect(call.matchDateTimeComponents, DateTimeComponents.time);
      expect(call.scheduleMode, AndroidScheduleMode.exactAllowWhileIdle);
      expect(call.scheduledDate.hour, 8);
      expect(call.scheduledDate.minute, 30);
      expect(call.payload, 'check_in_reminder:g1');
      expect(
        call.notificationDetails?.channelId,
        CheckInReminderService.channelId,
      );
      expect(call.notificationDetails?.icon, CheckInReminderService.smallIcon);
    });

    test('通道用新 id 且以高重要性创建', () async {
      await CheckInReminderService.saveSettings(settings('g1'));

      expect(backend.createdChannels, hasLength(1));
      expect(backend.createdChannels.single.id, 'check_in_reminder_v1');
      expect(backend.createdChannels.single.importance, Importance.high);
    });

    test('重复保存不会换通知 id', () async {
      await CheckInReminderService.saveSettings(settings('g1'));
      final first = backend.scheduledCalls.last.id;

      await CheckInReminderService.saveSettings(settings('g1', hour: 9));
      final second = backend.scheduledCalls.last.id;

      expect(second, first, reason: 'id 稳定才能覆盖而不是堆积通知');
      expect(backend.scheduledCalls.last.scheduledDate.hour, 9);
    });

    test('多个目标各自独立 id，互不干扰', () async {
      await CheckInReminderService.saveSettings(settings('g1', name: '早睡'));
      await CheckInReminderService.saveSettings(settings('g2', name: '喝水'));

      final ids = backend.scheduledCalls.map((c) => c.id).toSet();
      expect(ids, hasLength(2));
      final payloads =
          backend.scheduledCalls.map((c) => c.payload).toSet();
      expect(payloads, <String>{
        'check_in_reminder:g1',
        'check_in_reminder:g2',
      });
    });

    test('关闭会取消排程并清掉设置', () async {
      await CheckInReminderService.saveSettings(settings('g1'));
      final notificationId = backend.scheduledCalls.single.id;
      backend.cancelledIds.clear();

      await CheckInReminderService.saveSettings(
        settings('g1', enabled: false),
      );

      expect(backend.cancelledIds, contains(notificationId));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('check_in_reminder_g1_enabled'), isFalse);
    });

    test('删除目标会取消排程并释放通知 id', () async {
      await CheckInReminderService.saveSettings(settings('g1'));
      final notificationId = backend.scheduledCalls.single.id;

      await CheckInReminderService.removeSettings('g1');

      expect(backend.cancelledIds, contains(notificationId));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('check_in_reminder_g1_hour'), isNull);
      expect(prefs.getString('check_in_reminder_ids'), isNull);
    });

    test('上限用尽时明确报错，不静默失败', () async {
      // 先占满 id 段
      for (var i = 0; i <= 100; i++) {
        await CheckInReminderService.saveSettings(settings('g$i'));
      }

      final result = await CheckInReminderService.saveSettings(
        settings('overflow'),
      );

      expect(result.ok, isFalse);
      expect(result.message, contains('上限'));
    });
  });

  group('可提醒区间', () {
    test('已归档的目标不排程', () async {
      await CheckInReminderService.saveSettings(
        settings('g1').copyWith(endDateMs: null),
      );
      backend.scheduledCalls.clear();
      backend.pending = <PendingNotificationRequest>[];

      await CheckInReminderService.reconcile(
        allGoals: <CheckInGoal>[goal('g1', isArchived: true)],
        force: true,
      );

      expect(backend.scheduledCalls, isEmpty);
    });

    test('已过结束日期的目标不排程', () async {
      await CheckInReminderService.saveSettings(settings('g1'));
      backend.scheduledCalls.clear();
      backend.pending = <PendingNotificationRequest>[];

      await CheckInReminderService.reconcile(
        allGoals: <CheckInGoal>[
          goal(
            'g1',
            startDate: DateTime(2020, 1, 1),
            endDate: DateTime(2020, 2, 1),
          ),
        ],
        force: true,
      );

      expect(backend.scheduledCalls, isEmpty);
    });

    test('还没开始的目标不排程', () async {
      backend.pending = <PendingNotificationRequest>[];
      await CheckInReminderService.saveSettings(
        settings('g1').copyWith(
          startDateMs: DateTime(2099, 1, 1).millisecondsSinceEpoch,
        ),
      );

      expect(backend.scheduledCalls, isEmpty);
    });

    test('结束日期很近但仍在区间内时照常排程', () async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await CheckInReminderService.saveSettings(
        settings('g1').copyWith(
          startDateMs: DateTime.now()
              .subtract(const Duration(days: 1))
              .millisecondsSinceEpoch,
          endDateMs: tomorrow.millisecondsSinceEpoch,
        ),
      );

      expect(backend.scheduledCalls, hasLength(1));
    });
  });

  group('与目标列表对齐', () {
    test('目标已不存在时取消提醒（孤儿清理）', () async {
      await CheckInReminderService.saveSettings(settings('gone'));
      final notificationId = backend.scheduledCalls.single.id;
      backend.cancelledIds.clear();

      await CheckInReminderService.reconcile(
        allGoals: <CheckInGoal>[goal('other')],
        force: true,
      );

      expect(backend.cancelledIds, contains(notificationId));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('check_in_reminder_ids'), isNull);
    });

    test('用真实目标刷新冗余的目标名与日期区间', () async {
      await CheckInReminderService.saveSettings(settings('g1', name: '旧名字'));

      await CheckInReminderService.reconcile(
        allGoals: <CheckInGoal>[
          goal('g1', name: '新名字', endDate: DateTime(2099, 1, 1)),
        ],
        force: true,
      );

      final refreshed = await CheckInReminderService.loadSettings('g1');
      expect(refreshed.goalName, '新名字');
      expect(refreshed.endDateMs, DateTime(2099, 1, 1).millisecondsSinceEpoch);
    });

    test('排定已被系统清掉时会补登', () async {
      await CheckInReminderService.saveSettings(settings('g1'));
      backend.scheduledCalls.clear();
      backend.pending = <PendingNotificationRequest>[];

      await CheckInReminderService.reconcile(force: true);

      expect(backend.scheduledCalls, hasLength(1));
    });

    test('pending 里已有且配置未变时不重复登记', () async {
      await CheckInReminderService.saveSettings(settings('g1'));
      final notificationId = backend.scheduledCalls.single.id;
      backend.pending = <PendingNotificationRequest>[
        PendingNotificationRequest(
          notificationId,
          null,
          null,
          'check_in_reminder:g1',
        ),
      ];
      backend.scheduledCalls.clear();

      await CheckInReminderService.reconcile(force: true);

      expect(backend.scheduledCalls, isEmpty);
    });
  });

  group('权限与降级', () {
    test('时区不可用时不排程', () async {
      ReminderPlatform.timezoneIdentifierOverride =
          () async => throw StateError('读取时区失败');

      final result = await CheckInReminderService.saveSettings(settings('g1'));

      expect(backend.scheduledCalls, isEmpty);
      expect(result.ok, isFalse);
      expect(result.message, contains('时区'));
    });

    test('通知权限未授予时不排程并如实告知', () async {
      backend.notificationsAllowed = false;
      backend.notificationPermissionResult = false;

      final result = await CheckInReminderService.saveSettings(settings('g1'));

      expect(backend.scheduledCalls, isEmpty);
      expect(result.ok, isFalse);
      expect(result.message, contains('通知权限'));
    });

    test('缺少精确闹钟权限时降级为不精确排程并提示', () async {
      backend.exactAllowed = false;

      final result = await CheckInReminderService.saveSettings(settings('g1'));

      expect(
        backend.scheduledCalls.single.scheduleMode,
        AndroidScheduleMode.inexactAllowWhileIdle,
        reason: 'exactAllowWhileIdle 同样需要该权限，不是有效降级',
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('延迟'));
    });

    test('通道被用户关闭时提示提醒不会显示', () async {
      backend.channels = <AndroidNotificationChannel>[
        const AndroidNotificationChannel(
          CheckInReminderService.channelId,
          '打卡提醒',
          importance: Importance.none,
        ),
      ];

      final result = await CheckInReminderService.saveSettings(settings('g1'));

      expect(result.ok, isTrue);
      expect(result.message, contains('通道'));
    });
  });

  group('点击', () {
    test('payload 里解析出目标 id', () async {
      await CheckInReminderService.initialize();
      String? tapped;
      CheckInReminderService.bindTapHandler((goalId) => tapped = goalId);

      backend.onResponseHandler!(
        const NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotification,
          payload: 'check_in_reminder:goal-42',
        ),
      );

      expect(tapped, 'goal-42');
    });

    test('写日记提醒的 payload 不会被打卡路由接走', () async {
      await CheckInReminderService.initialize();
      var tapped = 0;
      CheckInReminderService.bindTapHandler((_) => tapped++);

      backend.onResponseHandler!(
        const NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotification,
          payload: 'diary_reminder',
        ),
      );

      expect(tapped, 0);
    });
  });

  group('非 Android', () {
    test('桌面端整体短路', () async {
      ReminderPlatform.androidPlatformOverride = false;
      backend.calls.clear();

      final result = await CheckInReminderService.saveSettings(settings('g1'));

      expect(result.ok, isFalse);
      expect(backend.calls, isEmpty);
    });
  });
}
