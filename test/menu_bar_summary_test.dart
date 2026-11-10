import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/utils/menu_bar_summary.dart';

TimeSlot _slot(
  int hour,
  int minute10, {
  String? label,
  String? categoryId,
  Color? color,
  bool recorded = true,
  bool calendar = false,
}) {
  return TimeSlot(
    hour: hour,
    minute10: minute10,
    recorded: recorded,
    label: label,
    categoryId: categoryId,
    color: color,
    isFromCalendar: calendar,
  );
}

List<TimeSlot> _day(List<TimeSlot> recorded) {
  final slots = <TimeSlot>[];
  for (var hour = 0; hour < 24; hour++) {
    for (var minute10 = 0; minute10 < 6; minute10++) {
      TimeSlot? match;
      for (final slot in recorded) {
        if (slot.hour == hour && slot.minute10 == minute10) {
          match = slot;
          break;
        }
      }
      slots.add(match ?? TimeSlot(hour: hour, minute10: minute10));
    }
  }
  return slots;
}

void main() {
  test('空槽不会产生分段', () {
    expect(buildMenuBarSpans(_day(const [])), isEmpty);
    final summary = buildMenuBarSummary(
      slots: _day(const []),
      now: DateTime(2026, 11, 10, 10),
    );
    expect(summary.hasRecorded, isFalse);
    expect(summary.current, isNull);
    expect(summary.recordedMinutes, 0);
  });

  test('相邻同标签同分类合并成一段', () {
    final slots = _day([
      _slot(9, 0, label: '站会', categoryId: 'c1', color: Colors.blue),
      _slot(9, 1, label: '站会', categoryId: 'c1', color: Colors.blue),
      _slot(9, 2, label: '站会', categoryId: 'c1', color: Colors.blue),
    ]);
    final spans = buildMenuBarSpans(slots);
    expect(spans, hasLength(1));
    expect(spans.single.startMinute, 9 * 60);
    expect(spans.single.endMinute, 9 * 60 + 30);
    expect(spans.single.minutes, 30);
  });

  test('换标签、换分类、断档都会拆成新段', () {
    final slots = _day([
      _slot(9, 0, label: '站会', categoryId: 'c1'),
      _slot(9, 1, label: '写方案', categoryId: 'c1'),
      _slot(9, 2, label: '写方案', categoryId: 'c2'),
      _slot(9, 3, label: '写方案', categoryId: 'c2'),
      // 9:40 空
      _slot(9, 5, label: '写方案', categoryId: 'c2'),
    ]);
    final spans = buildMenuBarSpans(slots);
    expect(spans.map((s) => s.minutes).toList(), [10, 10, 20, 10]);
    expect(spans.last.startMinute, 9 * 60 + 50);
  });

  test('未记录或空标签的槽不会进入分段', () {
    final slots = _day([
      _slot(9, 0, label: '', categoryId: 'c1'),
      _slot(9, 1, label: '站会', categoryId: 'c1', recorded: false),
      _slot(9, 2, label: '站会', categoryId: 'c1'),
    ]);
    final spans = buildMenuBarSpans(slots);
    expect(spans, hasLength(1));
    expect(spans.single.startMinute, 9 * 60 + 20);
  });

  test('当前段按左闭右开命中', () {
    final slots = _day([
      _slot(9, 0, label: '站会', categoryId: 'c1'),
      _slot(9, 1, label: '站会', categoryId: 'c1'),
    ]);

    expect(
      buildMenuBarSummary(
        slots: slots,
        now: DateTime(2026, 11, 10, 9, 0),
      ).current?.startMinute,
      540,
    );
    expect(
      buildMenuBarSummary(
        slots: slots,
        now: DateTime(2026, 11, 10, 9, 15),
      ).current?.startMinute,
      540,
    );
    // 9:20 是结束边界，不再属于这一段
    expect(
      buildMenuBarSummary(
        slots: slots,
        now: DateTime(2026, 11, 10, 9, 20),
      ).current,
      isNull,
    );
  });

  test('已记录时长按分段求和', () {
    final slots = _day([
      _slot(9, 0, label: '站会', categoryId: 'c1'),
      _slot(9, 1, label: '站会', categoryId: 'c1'),
      _slot(14, 0, label: '午休', categoryId: 'c2'),
    ]);
    final summary = buildMenuBarSummary(
      slots: slots,
      now: DateTime(2026, 11, 10, 12),
    );
    expect(summary.recordedMinutes, 30);
    expect(summary.spans, hasLength(2));
  });

  test('分类颜色优先于槽位里保存的旧颜色', () {
    final slots = _day([
      _slot(9, 0, label: '站会', categoryId: 'c1', color: Colors.blue),
    ]);
    final summary = buildMenuBarSummary(
      slots: slots,
      now: DateTime(2026, 11, 10, 9),
      categories: [
        Category(id: 'c1', name: '工作', color: Colors.red),
      ],
    );
    expect(summary.spans.single.color, Colors.red);
  });

  test('概览条几何按 1440 分钟映射', () {
    final slots = _day([
      _slot(0, 0, label: '零点', categoryId: 'c1'),
      _slot(12, 0, label: '中午', categoryId: 'c1'),
    ]);
    final segments = buildMenuBarBarSegments(buildMenuBarSpans(slots));
    expect(segments, hasLength(2));
    expect(segments.first.left, 0);
    expect(segments.first.width, closeTo(10 / 1440, 0.0001));
    expect(segments.last.left, closeTo(720 / 1440, 0.0001));
    expect(segments.last.width, closeTo(10 / 1440, 0.0001));
  });

  test('时长与区间格式化', () {
    expect(formatMenuBarDuration(0), '0分钟');
    expect(formatMenuBarDuration(45), '45分钟');
    expect(formatMenuBarDuration(60), '1小时');
    expect(formatMenuBarDuration(200), '3小时20分钟');
    expect(formatMenuBarRange(570, 610), '09:30-10:10');
    expect(formatMenuBarRange(0, 1440), '00:00-24:00');
  });
}
