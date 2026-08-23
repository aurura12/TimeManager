import 'package:googleapis/calendar/v3.dart' as calendar;

import '../models/calendar_block.dart';
import '../utils/local_day_range.dart';

CalendarBlock? calendarEventToBlock(calendar.Event event, DateTime date) {
  final startBoundary = event.start;
  final endBoundary = event.end;

  late final DateTime localStart;
  late final DateTime localEnd;
  if (startBoundary?.dateTime != null && endBoundary?.dateTime != null) {
    localStart = startBoundary!.dateTime!.toLocal();
    localEnd = endBoundary!.dateTime!.toLocal();
  } else if (startBoundary?.date != null && endBoundary?.date != null) {
    final startDate = startBoundary!.date!;
    final endDate = endBoundary!.date!;
    localStart = DateTime(startDate.year, startDate.month, startDate.day);
    localEnd = DateTime(endDate.year, endDate.month, endDate.day);
  } else {
    return null;
  }

  final title = event.summary?.trim();
  if (title == null || title.isEmpty) return null;

  final dayRange = localDayRange(date);
  final dayStart = dayRange.start;
  final dayEnd = dayRange.end;

  if (!localEnd.isAfter(dayStart) || !localStart.isBefore(dayEnd)) {
    return null;
  }

  final clippedStart = localStart.isBefore(dayStart) ? dayStart : localStart;
  final clippedEnd = localEnd.isAfter(dayEnd) ? dayEnd : localEnd;
  if (!clippedEnd.isAfter(clippedStart)) return null;

  return CalendarBlock(
    title: title,
    start: clippedStart,
    end: clippedEnd,
    eventId: event.id,
  );
}
