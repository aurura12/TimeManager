import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/services/calendar_slot_refresh.dart';

void main() {
  test('calendar refresh clears live imports but preserves calendar tombstones',
      () {
    final liveImport = TimeSlot(
      hour: 8,
      minute10: 0,
      recorded: true,
      isFromCalendar: true,
    );
    final calendarTombstone = TimeSlot(
      hour: 9,
      minute10: 0,
      isFromCalendar: true,
      deletedAt: DateTime.fromMillisecondsSinceEpoch(1787443200123),
    );

    expect(shouldClearCalendarSlotForRefresh(liveImport), isTrue);
    expect(shouldClearCalendarSlotForRefresh(calendarTombstone), isFalse);
  });
}
