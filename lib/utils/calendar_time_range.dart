import 'local_day_range.dart';

List<int> calendarTimeRangeToSlotIndices(
  DateTime start,
  DateTime end,
  DateTime day,
) {
  final dayRange = localDayRange(day);
  final dayStart = dayRange.start;
  final dayEnd = dayRange.end;

  final clippedStart = start.isBefore(dayStart) ? dayStart : start;
  final clippedEnd = end.isAfter(dayEnd) ? dayEnd : end;
  if (!clippedEnd.isAfter(clippedStart)) return [];

  final startIndex = clippedStart.hour * 6 + clippedStart.minute ~/ 10;
  final endIndex = clippedEnd.isAtSameMomentAs(dayEnd)
      ? 144
      : _endSlotIndexExclusive(clippedEnd);
  if (endIndex <= startIndex) return [];

  return List.generate(endIndex - startIndex, (i) => startIndex + i);
}

int _endSlotIndexExclusive(DateTime end) {
  if (end.minute % 10 == 0 && end.second == 0 && end.millisecond == 0) {
    return end.hour * 6 + end.minute ~/ 10;
  }
  return end.hour * 6 + (end.minute + 9) ~/ 10;
}
