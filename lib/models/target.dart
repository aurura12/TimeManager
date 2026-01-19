import 'package:flutter/material.dart';

enum TargetType { duration, timePoint, frequency }

class Target {
  final String id;
  final String name;
  final TargetType type;
  final Color color;
  final String period;
  final String compareType;

  // 根据类型不同的可选字段
  final double durationHours;
  final int frequencyCount;
  final String targetTime;
  final String startTime;
  final String endTime;

  Target({
    required this.id,
    required this.name,
    required this.type,
    required this.color,
    required this.period,
    this.compareType = "超过",
    this.durationHours = 0.0,
    this.frequencyCount = 0,
    this.targetTime = "",
    this.startTime = "",
    this.endTime = "",
  });

  // 将对象转换为 Map (JSON)
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.index, // 存储枚举的索引
      'color': color.toARGB32(), // 存储颜色的整数值
      'period': period,
      'compareType': compareType,
      'durationHours': durationHours,
      'frequencyCount': frequencyCount,
      'targetTime': targetTime,
      'startTime': startTime,
      'endTime': endTime,
    };
  }

  // 从 Map (JSON) 创建对象
  factory Target.fromJson(Map<String, dynamic> json) {
    return Target(
      id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name'],
      type: TargetType.values[json['type']],
      color: Color(json['color']),
      period: json['period'],
      compareType: json['compareType'] ?? "超过",
      durationHours: (json['durationHours'] as num?)?.toDouble() ?? 0.0,
      frequencyCount: json['frequencyCount'] ?? 0,
      targetTime: json['targetTime'] ?? "",
      startTime: json['startTime'] ?? "",
      endTime: json['endTime'] ?? "",
    );
  }
}
