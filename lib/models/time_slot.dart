class TimeSlot {
  final int hour;
  final int minute10;
  bool recorded; // 去掉 final，改为可变的

  TimeSlot({
    required this.hour,
    required this.minute10,
    this.recorded = false,
  });
}
