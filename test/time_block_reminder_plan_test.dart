import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_block_reminder.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/utils/time_block_reminder_plan.dart';

List<TimeSlot> emptySlots() => List<TimeSlot>.generate(
      144,
      (index) => TimeSlot(hour: index ~/ 6, minute10: index % 6),
    );

void paint(
  List<TimeSlot> slots,
  int fromMinute,
  int toMinute, {
  String label = '会议',
  String? categoryId = 'cat_work',
  bool fromCalendar = false,
}) {
  for (var minute = fromMinute; minute < toMinute; minute += 10) {
    slots[minute ~/ 10]
      ..recorded = true
      ..label = label
      ..categoryId = categoryId
      ..color = const Color(0xFF3366FF)
      ..isFromCalendar = fromCalendar;
  }
}

TimeBlockReminderDay day(DateTime date, List<TimeSlot> slots) =>
    TimeBlockReminderDay(date: date, slots: slots);

void main() {
  final today = DateTime(2026, 11, 5);

  group('聚块', () {
    test('连续同标签同分类的槽位合成一个块', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60 + 30);
      final occurrences = collectTimeBlockOccurrences(
        day(today, slots),
        leadMinutes: 5,
      );
      expect(occurrences, hasLength(1));
      expect(occurrences.single.startIndex, 54);
      expect(occurrences.single.endIndex, 62);
      expect(occurrences.single.startAt, DateTime(2026, 11, 5, 9));
      expect(occurrences.single.endAt, DateTime(2026, 11, 5, 10, 30));
      expect(occurrences.single.fireAt, DateTime(2026, 11, 5, 8, 55));
    });

    test('不同事件名的相邻槽位不合并', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60, label: '会议');
      paint(slots, 10 * 60, 11 * 60, label: '写代码');
      final occurrences = collectTimeBlockOccurrences(
        day(today, slots),
        leadMinutes: 0,
      );
      expect(occurrences.map((o) => o.label), ['会议', '写代码']);
    });

    test('不同分类的同名槽位不合并', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60, categoryId: 'a');
      paint(slots, 10 * 60, 11 * 60, categoryId: 'b');
      final occurrences = collectTimeBlockOccurrences(
        day(today, slots),
        leadMinutes: 0,
      );
      expect(occurrences, hasLength(2));
    });

    test('跳过日历导入、空标签与未记录的槽位', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60, fromCalendar: true);
      slots[72]..recorded = true..label = '   '..color = const Color(0xFF000000);
      slots[80].label = '只有名字没有记录';
      final occurrences = collectTimeBlockOccurrences(
        day(today, slots),
        leadMinutes: 0,
      );
      expect(occurrences, isEmpty);
    });

    test('23:50 开始的块在当天 24:00 结束', () {
      final slots = emptySlots();
      paint(slots, 23 * 60 + 50, 24 * 60);
      final occurrences = collectTimeBlockOccurrences(
        day(today, slots),
        leadMinutes: 0,
      );
      expect(occurrences.single.endAt, DateTime(2026, 11, 6));
    });
  });

  group('计划判定', () {
    test('已结束的块不排程，并进入 stale', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60);
      final id = timeBlockReminderNotificationId(
        date: today,
        startIndex: 54,
      );
      final plan = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 5,
        now: DateTime(2026, 11, 5, 11),
        handled: const {},
        pendingIds: {id},
        knownIds: {id},
      );
      expect(plan.toSchedule, isEmpty);
      expect(plan.staleIds, {id});
      expect(plan.handled, isEmpty);
      expect(plan.endedCount, 1);
    });

    test('已过开始但未结束的块补提醒', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60);
      final now = DateTime(2026, 11, 5, 9, 20);
      final plan = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 10,
        now: now,
        handled: const {},
        pendingIds: const {},
        knownIds: const {},
      );
      expect(plan.toSchedule, hasLength(1));
      expect(plan.toSchedule.single.catchUp, isTrue);
      expect(plan.toSchedule.single.fireAt, now);
      expect(plan.catchUpCount, 1);
      expect(plan.toSchedule.single.body, contains('已经开始'));
    });

    test('补提醒只发生一次（去重记录命中后不再排）', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60);
      final now = DateTime(2026, 11, 5, 9, 20);
      final first = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 10,
        now: now,
        handled: const {},
        pendingIds: const {},
        knownIds: const {},
      );
      final second = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 10,
        now: now.add(const Duration(minutes: 5)),
        handled: first.handled,
        pendingIds: const {},
        knownIds: const {},
      );
      expect(second.toSchedule, isEmpty);
      expect(second.scheduledCount, 1);
    });

    test('未来的块按提前量排程', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60);
      final plan = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 5,
        now: DateTime(2026, 11, 5, 8),
        handled: const {},
        pendingIds: const {},
        knownIds: const {},
      );
      expect(plan.toSchedule.single.fireAt, DateTime(2026, 11, 5, 8, 55));
      expect(plan.toSchedule.single.catchUp, isFalse);
      expect(plan.toSchedule.single.body, contains('还剩 5 分钟'));
      expect(plan.nextFireAt, DateTime(2026, 11, 5, 8, 55));
    });

    test('准点提醒的正文不带剩余时间', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60);
      final plan = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 0,
        now: DateTime(2026, 11, 5, 8),
        handled: const {},
        pendingIds: const {},
        knownIds: const {},
      );
      expect(plan.toSchedule.single.body, '09:00 开始');
    });

    test('已在 pending 且指纹一致的块不重复登记', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60);
      final now = DateTime(2026, 11, 5, 8);
      final first = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 5,
        now: now,
        handled: const {},
        pendingIds: const {},
        knownIds: const {},
      );
      final id = first.toSchedule.single.id;
      final second = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 5,
        now: now.add(const Duration(minutes: 1)),
        handled: first.handled,
        pendingIds: {id},
        knownIds: {id},
      );
      expect(second.toSchedule, isEmpty);
      expect(second.staleIds, isEmpty);
      expect(second.scheduledCount, 1);
    });

    test('改提前量后重新排程', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60);
      final now = DateTime(2026, 11, 5, 8);
      final first = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 5,
        now: now,
        handled: const {},
        pendingIds: const {},
        knownIds: const {},
      );
      final id = first.toSchedule.single.id;
      final second = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 15,
        now: now,
        handled: first.handled,
        pendingIds: {id},
        knownIds: {id},
      );
      expect(second.toSchedule, hasLength(1));
      expect(second.toSchedule.single.fireAt, DateTime(2026, 11, 5, 8, 45));
    });

    test('块被删除后旧 id 进入 stale', () {
      final slots = emptySlots();
      paint(slots, 9 * 60, 10 * 60);
      final now = DateTime(2026, 11, 5, 8);
      final first = buildTimeBlockReminderPlan(
        days: [day(today, slots)],
        leadMinutes: 5,
        now: now,
        handled: const {},
        pendingIds: const {},
        knownIds: const {},
      );
      final id = first.toSchedule.single.id;
      final second = buildTimeBlockReminderPlan(
        days: [day(today, emptySlots())],
        leadMinutes: 5,
        now: now,
        handled: first.handled,
        pendingIds: {id},
        knownIds: {id},
      );
      expect(second.toSchedule, isEmpty);
      expect(second.staleIds, {id});
      expect(second.handled, isEmpty);
    });
  });

  group('通知 id', () {
    test('同一日期与起点恒等，跨天不冲突', () {
      final ids = <int>{};
      for (var offset = 0; offset < 3; offset++) {
        final date = today.add(Duration(days: offset));
        final id = timeBlockReminderNotificationId(date: date, startIndex: 54);
        expect(
          id,
          timeBlockReminderNotificationId(date: date, startIndex: 54),
        );
        ids.add(id);
      }
      expect(ids, hasLength(3));
    });

    test('全部落在 2400–2831 区间内', () {
      for (var offset = 0; offset < 3; offset++) {
        final date = today.add(Duration(days: offset));
        for (var index = 0; index < 144; index++) {
          final id = timeBlockReminderNotificationId(
            date: date,
            startIndex: index,
          );
          expect(
            id,
            inInclusiveRange(timeBlockReminderIdBase, timeBlockReminderIdMax),
          );
        }
      }
    });

    test('区间过滤不动其他提醒的 id', () {
      expect(
        timeBlockReminderIdsInRange([2001, 2002, 2200, 2400, 2831, 2832]),
        {2400, 2831},
      );
    });
  });
}
