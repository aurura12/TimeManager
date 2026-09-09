import 'package:flutter/material.dart';

enum TargetType { duration, timePoint, frequency }

class Target {
  final String id;
  final String name;
  final String categoryId;
  final TargetType type;
  final Color color;
  final String period;
  final String compareType;

  final double durationHours;
  final int frequencyCount;
  final String targetTime;
  final String startTime;
  final String endTime;

  /// 目标最后修改时间（毫秒时间戳），用于跨设备合并冲突。
  /// 旧版本数据没有该字段，加载时由 TimeProvider 迁移补齐。
  final int updatedAt;

  Target({
    required this.id,
    required this.name,
    this.categoryId = '',
    required this.type,
    required this.color,
    required this.period,
    this.compareType = "超过",
    this.durationHours = 0.0,
    this.frequencyCount = 0,
    this.targetTime = "",
    this.startTime = "",
    this.endTime = "",
    this.updatedAt = 0,
  });

  Target copyWith({
    String? id,
    String? name,
    String? categoryId,
    TargetType? type,
    Color? color,
    String? period,
    String? compareType,
    double? durationHours,
    int? frequencyCount,
    String? targetTime,
    String? startTime,
    String? endTime,
    int? updatedAt,
  }) {
    return Target(
      id: id ?? this.id,
      name: name ?? this.name,
      categoryId: categoryId ?? this.categoryId,
      type: type ?? this.type,
      color: color ?? this.color,
      period: period ?? this.period,
      compareType: compareType ?? this.compareType,
      durationHours: durationHours ?? this.durationHours,
      frequencyCount: frequencyCount ?? this.frequencyCount,
      targetTime: targetTime ?? this.targetTime,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (categoryId.isNotEmpty) 'categoryId': categoryId,
      'type': type.index,
      'color': color.toARGB32(),
      'period': period,
      'compareType': compareType,
      'durationHours': durationHours,
      'frequencyCount': frequencyCount,
      'targetTime': targetTime,
      'startTime': startTime,
      'endTime': endTime,
      'updatedAt': updatedAt,
    };
  }

  factory Target.fromJson(Map<String, dynamic> json) {
    final typeIndex = json['type'] as int?;
    return Target(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? '',
      categoryId: json['categoryId'] as String? ?? '',
      type: (typeIndex != null &&
              typeIndex >= 0 &&
              typeIndex < TargetType.values.length)
          ? TargetType.values[typeIndex]
          : TargetType.duration,
      color: Color(json['color'] as int? ?? 0xFF9CB86A),
      period: json['period']?.toString() ?? '每天',
      compareType: json['compareType']?.toString() ?? "超过",
      durationHours: (json['durationHours'] as num?)?.toDouble() ?? 0.0,
      frequencyCount: json['frequencyCount'] as int? ?? 0,
      targetTime: json['targetTime']?.toString() ?? "",
      startTime: json['startTime']?.toString() ?? "",
      endTime: json['endTime']?.toString() ?? "",
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}
