/// 每个自然日保留一次起床时间，精确到分钟。
class WakeUpRecord {
  WakeUpRecord(DateTime time, {this.updatedAt = 0})
      : time =
            DateTime(time.year, time.month, time.day, time.hour, time.minute);

  final DateTime time;

  /// 最后一次记录或修改的时间戳，与起床时刻分开，用于跨设备合并。
  final int updatedAt;

  WakeUpRecord withUpdatedAt(int value) => WakeUpRecord(time, updatedAt: value);

  String get dateKey => keyForDate(time);
  int get minuteOfDay => time.hour * 60 + time.minute;
  String get timeLabel => labelForMinute(minuteOfDay);

  Duration elapsedAt(DateTime now) {
    final elapsed = now.difference(time);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  Map<String, dynamic> toJson() => {
        'date': dateKey,
        'hour': time.hour,
        'minute': time.minute,
        'updatedAt': updatedAt,
      };

  factory WakeUpRecord.fromJson(Map<String, dynamic> json) {
    final date = json['date'];
    final hour = json['hour'];
    final minute = json['minute'];
    final updatedAt = json['updatedAt'] ?? 0;
    if (date is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        hour is! int ||
        hour < 0 ||
        hour > 23 ||
        minute is! int ||
        minute < 0 ||
        minute > 59 ||
        updatedAt is! int ||
        updatedAt < 0) {
      throw const FormatException('起床记录的日期或时间无效');
    }
    final day = DateTime.tryParse(date);
    if (day == null || !isValidDateKey(date)) {
      throw const FormatException('起床记录的日期无效');
    }
    return WakeUpRecord(DateTime(day.year, day.month, day.day, hour, minute),
        updatedAt: updatedAt);
  }

  static bool isValidDateKey(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final date = DateTime.tryParse(value);
    return date != null && keyForDate(date) == value;
  }

  static String keyForDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static String labelForMinute(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';
}
