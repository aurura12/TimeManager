import '../models/time_slot.dart';

/// 两个相邻槽位只有在视觉和事件语义都一致时才可以合并显示。
bool canJoinTimeSlots(TimeSlot left, TimeSlot right) {
  return left.recorded &&
      right.recorded &&
      left.label != null &&
      left.label == right.label &&
      left.categoryId == right.categoryId &&
      left.color == right.color &&
      left.isFromCalendar == right.isFromCalendar &&
      left.calendarEventId == right.calendarEventId;
}
