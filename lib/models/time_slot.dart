import 'package:flutter/material.dart';

enum Priority {
  none(Colors.grey, "无"),
  high(Colors.redAccent, "高"),
  medium(Colors.orangeAccent, "中"),
  low(Colors.lightBlueAccent, "低");

  final Color color;
  final String label;
  const Priority(this.color, this.label);
}

class TimeSlot {
  final int hour;
  final int minute10;
  Priority priority;

  TimeSlot({required this.hour, required this.minute10, this.priority = Priority.none});

  Map<String, dynamic> toJson() => {'h': hour, 'm': minute10, 'p': priority.index};

  factory TimeSlot.fromJson(Map<String, dynamic> json) => TimeSlot(
    hour: json['h'],
    minute10: json['m'],
    priority: Priority.values[json['p']],
  );
}