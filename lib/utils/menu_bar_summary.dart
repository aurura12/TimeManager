import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/painting.dart';

import '../models/category.dart';
import '../models/time_slot.dart';
import 'time_slot_segment.dart';

/// 一天按分钟计的跨度：菜单栏概览条与块列表都用同一套刻度。
const int menuBarMinutesPerDay = 24 * 60;

/// 今天的一段连续记录（由相邻 10 分钟槽合并而来）。
@foundation.immutable
class MenuBarSpan {
  const MenuBarSpan({
    required this.startMinute,
    required this.endMinute,
    required this.label,
    required this.categoryId,
    required this.color,
    required this.isFromCalendar,
  });

  final int startMinute;
  final int endMinute;
  final String label;
  final String? categoryId;
  final Color? color;
  final bool isFromCalendar;

  int get minutes => endMinute - startMinute;

  bool containsMinute(int minute) =>
      minute >= startMinute && minute < endMinute;

  MenuBarSpan copyWith({int? endMinute, Color? color}) {
    return MenuBarSpan(
      startMinute: startMinute,
      endMinute: endMinute ?? this.endMinute,
      label: label,
      categoryId: categoryId,
      color: color ?? this.color,
      isFromCalendar: isFromCalendar,
    );
  }
}

/// 今日速览的数据快照。
@foundation.immutable
class MenuBarSummary {
  const MenuBarSummary({
    required this.spans,
    required this.current,
    required this.recordedMinutes,
  });

  static const empty = MenuBarSummary(
    spans: <MenuBarSpan>[],
    current: null,
    recordedMinutes: 0,
  );

  final List<MenuBarSpan> spans;
  final MenuBarSpan? current;
  final int recordedMinutes;

  bool get hasRecorded => recordedMinutes > 0;
}

/// 把 144 个 10 分钟槽合并成连续记录段。
///
/// 相邻槽只有在 [canJoinTimeSlots] 认为视觉与语义都一致时才合并，
/// 与记录页的连续块规则保持一致。
List<MenuBarSpan> buildMenuBarSpans(List<TimeSlot> slots) {
  final spans = <MenuBarSpan>[];
  TimeSlot? previous;

  for (final slot in slots) {
    if (!slot.recorded) {
      previous = null;
      continue;
    }
    final label = slot.label?.trim();
    if (label == null || label.isEmpty) {
      previous = null;
      continue;
    }
    final startMinute = slot.hour * 60 + slot.minute10 * 10;
    if (startMinute < 0 || startMinute >= menuBarMinutesPerDay) {
      previous = null;
      continue;
    }
    final endMinute = (startMinute + 10).clamp(0, menuBarMinutesPerDay);

    final last = spans.isEmpty ? null : spans.last;
    if (last != null &&
        previous != null &&
        last.endMinute == startMinute &&
        canJoinTimeSlots(previous, slot)) {
      spans[spans.length - 1] = last.copyWith(endMinute: endMinute);
    } else {
      spans.add(
        MenuBarSpan(
          startMinute: startMinute,
          endMinute: endMinute,
          label: label,
          categoryId: slot.categoryId,
          color: slot.color,
          isFromCalendar: slot.isFromCalendar,
        ),
      );
    }
    previous = slot;
  }

  return spans;
}

/// [now] 当天的速览：分段、当前段、已记录总时长。
///
/// [categories] 只用来纠正旧数据可能缺失的槽位颜色，查不到时仍用槽位自身颜色。
MenuBarSummary buildMenuBarSummary({
  required List<TimeSlot> slots,
  required DateTime now,
  List<Category> categories = const <Category>[],
}) {
  final colorByCategory = <String, Color>{
    for (final category in categories) category.id: category.color,
  };
  final spans = <MenuBarSpan>[
    for (final span in buildMenuBarSpans(slots))
      if (span.categoryId != null && colorByCategory.containsKey(span.categoryId))
        span.copyWith(color: colorByCategory[span.categoryId])
      else
        span,
  ];

  final nowMinute = now.hour * 60 + now.minute;
  MenuBarSpan? current;
  for (final span in spans) {
    if (span.containsMinute(nowMinute)) {
      current = span;
      break;
    }
  }

  var recordedMinutes = 0;
  for (final span in spans) {
    recordedMinutes += span.minutes;
  }

  return MenuBarSummary(
    spans: List<MenuBarSpan>.unmodifiable(spans),
    current: current,
    recordedMinutes: recordedMinutes,
  );
}

/// 中文时长：`1小时30分钟` / `45分钟` / `0分钟`。
String formatMenuBarDuration(int minutes) {
  final safe = minutes < 0 ? 0 : minutes;
  if (safe >= 60) {
    final hours = safe ~/ 60;
    final rest = safe % 60;
    return rest > 0 ? '$hours小时$rest分钟' : '$hours小时';
  }
  return '$safe分钟';
}

/// `09:30-10:10`；结束时间允许是 24:00。
String formatMenuBarRange(int startMinute, int endMinute) {
  String two(int value) => value.toString().padLeft(2, '0');
  final start = startMinute.clamp(0, menuBarMinutesPerDay);
  final end = endMinute.clamp(0, menuBarMinutesPerDay);
  return '${two(start ~/ 60)}:${two(start % 60)}-${two(end ~/ 60)}:${two(end % 60)}';
}