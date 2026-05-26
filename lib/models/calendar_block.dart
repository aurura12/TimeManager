class CalendarBlock {
  final String title;
  final DateTime start;
  final DateTime end;
  final String? eventId;

  CalendarBlock({
    required this.title,
    required this.start,
    required this.end,
    this.eventId,
  });
}
