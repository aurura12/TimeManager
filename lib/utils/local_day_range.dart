class LocalDayRange {
  final DateTime start;
  final DateTime end;

  const LocalDayRange({required this.start, required this.end});
}

LocalDayRange localDayRange(DateTime date) {
  final start = DateTime(date.year, date.month, date.day);
  return LocalDayRange(
    start: start,
    end: DateTime(date.year, date.month, date.day + 1),
  );
}
