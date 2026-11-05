import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/time_block_reminder.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/reminder_platform.dart';
import 'package:time_manager/services/time_block_reminder_service.dart';

import 'support/fake_reminder_backend.dart';

const MethodChannel _secureStorage =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

List<TimeSlot> emptySlots() => List<TimeSlot>.generate(
      144,
      (index) => TimeSlot(hour: index ~/ 6, minute10: index % 6),
    );

void paint(List<TimeSlot> slots, int fromMinute, int toMinute) {
  for (var minute = fromMinute; minute < toMinute; minute += 10) {
    slots[minute ~/ 10]
      ..recorded = true
      ..label = '会议'
      ..categoryId = 'cat_work'
      ..color = const Color(0xFF3366FF);
  }
}

/// 时间块提醒的行为约定。重点覆盖历史上真实踩过的坑：
/// 一次性排程不能用每日重复、时区失败不回退 UTC、未就绪不清空排程、
/// 未选身份只取消不写设置、只动自己的 id 段。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeReminderBackend backend;
  late DateTime now;
  late List<TimeSlot> slots;

  const enabled = TimeBlockReminderSettings(enabled: true, leadMinutes: 5);
  const disabled = TimeBlockReminderSettings(enabled: false, leadMinutes: 5);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    TimeBlockReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
    AppIdentityService.resetForTesting();

    backend = FakeReminderBackend();
    ReminderPlatform.backendOverride = backend;
    ReminderPlatform.androidPlatformOverride = true;
    ReminderPlatform.timezoneIdentifierOverride = () async => 'Asia/Shanghai';
    AppIdentityService.adoptManualKind(DiaryKind.g);

    now = DateTime(2026, 11, 5, 8);
    TimeBlockReminderService.clockOverride = () => now;

    slots = emptySlots();
    TimeBlockReminderService.attachScheduleSource(
      () => [TimeBlockReminderDay(date: DateTime(2026, 11, 5), slots: slots)],
    );
  });

  tearDown(() {
    TimeBlockReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorage, null);
  });

  group('平台与通道', () {
    test('非 Android 直接返回 unsupported，且不碰平台接口', () async {
      ReminderPlatform.androidPlatformOverride = false;
      final status = await TimeBlockReminderService.initialize();
      expect(status.issue, TimeBlockReminderIssue.unsupportedPlatform);
      expect(backend.calls, isEmpty);
    });

    test('创建独立通道，重要性为高', () async {
      await TimeBlockReminderService.initialize();
      expect(backend.createdChannels, hasLength(1));
      final channel = backend.createdChannels.single;
      expect(channel.id, TimeBlockReminderService.channelId);
      expect(channel.importance, Importance.high);
      expect(channel.id, isNot('diary_reminder_v2'));
      expect(channel.id, isNot('check_in_reminder_v1'));
    });
  });

  group('排程', () {
    test('按提前量登记一次性绝对时刻', () async {
      paint(slots, 9 * 60, 10 * 60);
      final status = await TimeBlockReminderService.saveSettings(enabled);

      expect(status.issue, TimeBlockReminderIssue.none);
      expect(status.scheduledCount, 1);

      final call = backend.scheduledCalls.single;
      expect(call.id, inInclusiveRange(2400, 2831));
      expect(call.scheduledDate.hour, 8);
      expect(call.scheduledDate.minute, 55);
      expect(call.matchDateTimeComponents, isNull);
      expect(call.scheduleMode, AndroidScheduleMode.exactAllowWhileIdle);
      expect(call.payload, 'time_block_reminder:2026-11-05:54');
      expect(call.notificationDetails?.channelId,
          TimeBlockReminderService.channelId);
      expect(call.notificationDetails?.icon,
          TimeBlockReminderService.smallIcon);
    });

    test('没有精确闹钟权限时降级为不精确', () async {
      backend.exactAllowed = false;
      paint(slots, 9 * 60, 10 * 60);
      final status = await TimeBlockReminderService.saveSettings(enabled);

      expect(backend.scheduledCalls.single.scheduleMode,
          AndroidScheduleMode.inexactAllowWhileIdle);
      expect(status.issue, TimeBlockReminderIssue.exactAlarmDenied);
    });

    test('时区不可用时不排程也不取消既有排程', () async {
      ReminderPlatform.timezoneIdentifierOverride = () async => '';
      paint(slots, 9 * 60, 10 * 60);
      backend.pending = <PendingNotificationRequest>[
        const PendingNotificationRequest(2400, null, null, null),
      ];
      final status = await TimeBlockReminderService.saveSettings(enabled);

      expect(status.issue, TimeBlockReminderIssue.timezoneUnavailable);
      expect(backend.scheduledCalls, isEmpty);
      expect(backend.cancelledIds, isEmpty);
    });

    test('已结束的块不排程，旧排程被取消', () async {
      now = DateTime(2026, 11, 5, 11);
      paint(slots, 9 * 60, 10 * 60);
      backend.pending = <PendingNotificationRequest>[
        const PendingNotificationRequest(2400, null, null, null),
      ];
      final status = await TimeBlockReminderService.saveSettings(enabled);

      expect(status.scheduledCount, 0);
      expect(backend.scheduledCalls, isEmpty);
      expect(backend.cancelledIds, contains(2400));
    });

    test('已开始未结束补提醒，且只补一次', () async {
      now = DateTime(2026, 11, 5, 9, 20);
      paint(slots, 9 * 60, 10 * 60);
      final status = await TimeBlockReminderService.saveSettings(enabled);

      expect(status.scheduledCount, 1);
      expect(backend.shownCalls, hasLength(1));
      expect(backend.shownCalls.single.payload,
          'time_block_reminder:2026-11-05:54');
      expect(backend.scheduledCalls, isEmpty);

      await TimeBlockReminderService.reconcile(force: true);
      expect(backend.shownCalls, hasLength(1));
    });

    test('块起点被编辑后取消旧 id、登记新 id', () async {
      paint(slots, 9 * 60, 10 * 60);
      await TimeBlockReminderService.saveSettings(enabled);
      final oldId = backend.scheduledCalls.single.id;

      backend.pending = <PendingNotificationRequest>[
        PendingNotificationRequest(oldId, null, null, null),
      ];
      backend.scheduledCalls.clear();
      backend.cancelledIds.clear();

      final moved = emptySlots();
      paint(moved, 10 * 60, 11 * 60);
      slots = moved;
      await TimeBlockReminderService.reconcile(force: true);

      expect(backend.cancelledIds, contains(oldId));
      expect(backend.scheduledCalls, hasLength(1));
      expect(backend.scheduledCalls.single.id, isNot(oldId));
      expect(backend.scheduledCalls.single.payload,
          'time_block_reminder:2026-11-05:60');
    });

    test('关闭提醒只取消自己的 id 段', () async {
      paint(slots, 9 * 60, 10 * 60);
      await TimeBlockReminderService.saveSettings(enabled);
      final ownId = backend.scheduledCalls.single.id;

      backend.pending = <PendingNotificationRequest>[
        const PendingNotificationRequest(2001, null, null, null),
        const PendingNotificationRequest(2200, null, null, null),
        PendingNotificationRequest(ownId, null, null, null),
      ];
      backend.cancelledIds.clear();

      final status = await TimeBlockReminderService.saveSettings(disabled);
      expect(status.scheduledCount, 0);
      expect(backend.cancelledIds, [ownId]);
    });

    test('数据未就绪时保留现有排程', () async {
      TimeBlockReminderService.attachScheduleSource(() => null);
      backend.pending = <PendingNotificationRequest>[
        const PendingNotificationRequest(2400, null, null, null),
      ];
      final status = await TimeBlockReminderService.saveSettings(enabled);

      expect(status.issue, TimeBlockReminderIssue.sourceUnavailable);
      expect(backend.cancelledIds, isEmpty);
      expect(backend.scheduledCalls, isEmpty);
    });

    test('通知权限关闭时取消本区间排程', () async {
      backend.notificationsAllowed = false;
      paint(slots, 9 * 60, 10 * 60);
      backend.pending = <PendingNotificationRequest>[
        const PendingNotificationRequest(2400, null, null, null),
      ];
      final status = await TimeBlockReminderService.saveSettings(enabled);

      expect(status.issue, TimeBlockReminderIssue.notificationsDenied);
      expect(backend.cancelledIds, [2400]);
      expect(backend.scheduledCalls, isEmpty);
    });

    test('非 force 的重复调用会被节流', () async {
      paint(slots, 9 * 60, 10 * 60);
      await TimeBlockReminderService.saveSettings(enabled);
      backend.calls.clear();
      backend.scheduledCalls.clear();

      await TimeBlockReminderService.reconcile();
      expect(backend.scheduledCalls, isEmpty);
      expect(backend.calls, isEmpty);
    });
  });

  group('身份与设置', () {
    test('未选身份时只取消、不写 identity_unbound 键', () async {
      AppIdentityService.resetForTesting();
      paint(slots, 9 * 60, 10 * 60);
      backend.pending = <PendingNotificationRequest>[
        const PendingNotificationRequest(2400, null, null, null),
      ];
      await TimeBlockReminderService.initialize();
      final status = await TimeBlockReminderService.reconcile(force: true);

      expect(status.issue, TimeBlockReminderIssue.identityUnavailable);
      expect(backend.cancelledIds, [2400]);
      expect(backend.scheduledCalls, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      final unbound =
          prefs.getKeys().where((key) => key.startsWith('identity_unbound')).toList();
      expect(unbound, isEmpty);
    });

    test('默认关闭、提前 5 分钟，读取设置不碰原生接口', () async {
      final settings = await TimeBlockReminderService.loadSettings();
      expect(settings.enabled, isFalse);
      expect(settings.leadMinutes, 5);
      expect(backend.calls, isEmpty);
    });

    test('保存的提前量超出范围时回落到默认值', () async {
      await TimeBlockReminderService.saveSettings(
        const TimeBlockReminderSettings(enabled: true, leadMinutes: 999),
      );
      final settings = await TimeBlockReminderService.loadSettings();
      expect(settings.leadMinutes, TimeBlockReminderSettings.defaultLeadMinutes);
    });
  });
}
