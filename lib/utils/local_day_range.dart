class LocalDayRange {
  final DateTime start;
  final DateTime end;

  const LocalDayRange({required this.start, required this.end});
}

/// 只保留年月日，作为「自然日」的比较基准。
DateTime localDayOf(DateTime date) => DateTime(date.year, date.month, date.day);

bool isSameLocalDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

LocalDayRange localDayRange(DateTime date) {
  final start = DateTime(date.year, date.month, date.day);
  return LocalDayRange(
    start: start,
    end: DateTime(date.year, date.month, date.day + 1),
  );
}
