import 'package:flutter/material.dart';

import '../models/time_slot.dart';
import '../models/time_slot_resize.dart';
import 'time_slot_segment.dart';

/// 一天固定 144 个 10 分钟槽位
const int kDaySlotCount = 144;

/// 一个逻辑时间块的闭区间范围。
///
/// 网格按行渲染，跨小时的块会被画成多段，但数据层面仍是同一段连续槽位。
class TimeBlockRange {
  const TimeBlockRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;

  bool contains(int index) => index >= start && index <= end;

  @override
  bool operator ==(Object other) =>
      other is TimeBlockRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TimeBlockRange($start..$end)';
}

/// 从 [index] 向两侧扫描，返回它所在的完整逻辑块（可跨小时）。
///
/// 未记录 / 没有事件名或颜色的槽位返回 null。扫描条件与渲染层一致，
/// 都使用 [canJoinTimeSlots]，避免出现「看起来是一块、拖的却是另一块」。
TimeBlockRange? findTimeBlockRange(List<TimeSlot> slots, int index) {
  if (index < 0 || index >= slots.length) return null;
  final anchor = slots[index];
  if (!anchor.recorded || anchor.label == null || anchor.color == null) {
    return null;
  }

  var start = index;
  while (start > 0 && canJoinTimeSlots(slots[start - 1], slots[start])) {
    start--;
  }
  var end = index;
  while (end < slots.length - 1 && canJoinTimeSlots(slots[end], slots[end + 1])) {
    end++;
  }
  return TimeBlockRange(start, end);
}

/// 把拖拽目标边界夹进合法区间。
///
/// 起点不能越过终点、终点不能越过起点，因此块至少保留 1 格；
/// 同时不会超出当天的槽位范围。
int clampTimeBlockResizeTarget({
  required TimeSlotResizeEdge edge,
  required int originalStart,
  required int originalEnd,
  required int targetIndex,
  int slotCount = kDaySlotCount,
}) {
  final low = edge == TimeSlotResizeEdge.start ? 0 : originalStart;
  final high =
      edge == TimeSlotResizeEdge.start ? originalEnd : slotCount - 1;
  return targetIndex.clamp(low, high);
}

/// 生成拖拽预览用的槽位副本：新范围写入块身份，被裁掉的旧范围清空。
///
/// 只用于渲染预览，不落库；范围没变化时直接返回原列表。
List<TimeSlot> applyTimeBlockResizePreview({
  required List<TimeSlot> slots,
  required int originalStart,
  required int originalEnd,
  required int newStart,
  required int newEnd,
  required String label,
  required String? categoryId,
  required Color color,
}) {
  if (newStart == originalStart && newEnd == originalEnd) return slots;

  final preview = [for (final slot in slots) _copySlot(slot)];

  for (var index = originalStart; index <= originalEnd; index++) {
    if (index >= newStart && index <= newEnd) continue;
    final slot = preview[index];
    slot.recorded = false;
    slot.label = null;
    slot.categoryId = null;
    slot.color = null;
    slot.isFromCalendar = false;
    slot.calendarEventId = null;
    slot.deletedAt = null;
  }

  for (var index = newStart; index <= newEnd; index++) {
    final slot = preview[index];
    slot.recorded = true;
    slot.label = label;
    slot.categoryId = categoryId;
    slot.color = color;
    slot.isFromCalendar = false;
    slot.calendarEventId = null;
    slot.deletedAt = null;
  }

  return preview;
}

TimeSlot _copySlot(TimeSlot slot) => TimeSlot(
      hour: slot.hour,
      minute10: slot.minute10,
      recorded: slot.recorded,
      label: slot.label,
      categoryId: slot.categoryId,
      color: slot.color,
      isFromCalendar: slot.isFromCalendar,
      calendarEventId: slot.calendarEventId,
      modifiedAt: slot.modifiedAt,
      deletedAt: slot.deletedAt,
    );
