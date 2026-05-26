class DailyReviewReminder {
  final bool enabled;
  final int hour;
  final int minute;

  const DailyReviewReminder({
    this.enabled = false,
    this.hour = 22,
    this.minute = 0,
  });

  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  DailyReviewReminder copyWith({
    bool? enabled,
    int? hour,
    int? minute,
  }) {
    return DailyReviewReminder(
      enabled: enabled ?? this.enabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
    );
  }
}
