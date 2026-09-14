import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
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
    // 历史数据/导入数据里数字字段可能是 String 或 double，
    // 一律宽松解析，避免单条类型不符导致整个目标被丢弃。
    final typeIndex = _asInt(json['type']);
    return Target(
      id: _asString(json['id']) ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: _asString(json['name']) ?? '',
      categoryId: _asString(json['categoryId']) ?? '',
      type: (typeIndex != null &&
              typeIndex >= 0 &&
              typeIndex < TargetType.values.length)
          ? TargetType.values[typeIndex]
          : TargetType.duration,
      // 与 Category 同理：颜色只能是不透明实色
      color: AppSemanticColors.opaque(Color(
          _asInt(json['color']) ?? AppSemanticColors.brand.toARGB32())),
      period: _asString(json['period']) ?? '每天',
      compareType: _asString(json['compareType']) ?? "超过",
      durationHours: _asNum(json['durationHours'])?.toDouble() ?? 0.0,
      frequencyCount: _asInt(json['frequencyCount']) ?? 0,
      targetTime: _asString(json['targetTime']) ?? "",
      startTime: _asString(json['startTime']) ?? "",
      endTime: _asString(json['endTime']) ?? "",
      updatedAt: _asInt(json['updatedAt']) ?? 0,
    );
  }

  static num? _asNum(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value.trim());
    return null;
  }

  static int? _asInt(dynamic value) => _asNum(value)?.toInt();

  static String? _asString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }
}
