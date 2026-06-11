class TargetCompletion {
  final String targetId;
  final DateTime date;
  final int count;

  const TargetCompletion({
    required this.targetId,
    required this.date,
    this.count = 1,
  });

  TargetCompletion copyWith({
    String? targetId,
    DateTime? date,
    int? count,
  }) {
    return TargetCompletion(
      targetId: targetId ?? this.targetId,
      date: date ?? this.date,
      count: count ?? this.count,
    );
  }

  String get dateKey =>
      "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";

  Map<String, dynamic> toJson() {
    return {
      'targetId': targetId,
      'date': date.toIso8601String(),
      'count': count,
    };
  }

  factory TargetCompletion.fromJson(Map<String, dynamic> json) {
    return TargetCompletion(
      targetId: json['targetId'] as String,
      date: DateTime.parse(json['date'] as String),
      count: json['count'] as int? ?? 1,
    );
  }
}

class TargetStreak {
  final DateTime startDate;
  final DateTime endDate;
  final int days;

  const TargetStreak({
    required this.startDate,
    required this.endDate,
    required this.days,
  });
}
