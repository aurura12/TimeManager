import '../models/time_slot.dart';

/// Google 日历重新拉取前，判断槽位是否应清理。
bool shouldClearCalendarSlotForRefresh(TimeSlot slot) =>
    slot.recorded && slot.isFromCalendar;
