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
  });
}
