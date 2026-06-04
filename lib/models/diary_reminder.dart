class DiaryReminder {
  final bool enabled;
  final int hour;
  final int minute;

  const DiaryReminder({
    this.enabled = false,
    this.hour = 21,
    this.minute = 0,
  });

  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  DiaryReminder copyWith({
    bool? enabled,
    int? hour,
    int? minute,
  }) {
    return DiaryReminder(
      enabled: enabled ?? this.enabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
    );
  }
}
