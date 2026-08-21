import 'package:flutter/material.dart';

class TimeSlot {
  final int hour;
  final int minute10;
  bool recorded;
  String? label;
  String? categoryId;
  Color? color;
  bool isFromCalendar;
  String? calendarEventId;

  /// 最后修改时间（epoch ms），用于日程同步的后写覆盖判断；旧数据为 null 视为最旧
  DateTime? modifiedAt;

  /// 删除时间（epoch ms）。非空表示该槽被用户删除（墓碑），
  /// 同步时输出 `{del: true}` entry，防止远端旧数据把它合并复活。
  DateTime? deletedAt;

  TimeSlot({
    required this.hour,
    required this.minute10,
    this.recorded = false,
    this.label,
    this.categoryId,
    this.color,
    this.isFromCalendar = false,
    this.calendarEventId,
    this.modifiedAt,
    this.deletedAt,
  });
}
