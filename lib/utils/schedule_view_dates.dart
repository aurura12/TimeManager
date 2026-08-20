/// Returns the dates whose schedule columns are visible around [currentDate].
///
/// Desktop shows the previous, current, and next day; mobile shows only the
/// selected day.
List<DateTime> scheduleDatesForView(
  DateTime currentDate, {
  required bool desktop,
}) {
  final day = DateTime(currentDate.year, currentDate.month, currentDate.day);
  if (!desktop) return [day];
  return [
    day.subtract(const Duration(days: 1)),
    day,
    day.add(const Duration(days: 1)),
  ];
}
