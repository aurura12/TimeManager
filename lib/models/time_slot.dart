import 'package:flutter/material.dart';

class TimeSlot {
  final int hour;
  final int minute10;
  bool recorded;
  String? label; // 记录的名称，如“语言”
  Color? color; // 对应的颜色
  bool isFromCalendar; // 从 Google 日历拉取的外部会议
  String? calendarEventId; // Google 日历事件 ID，用于忽略已删除的导入

  TimeSlot(
      {required this.hour,
      required this.minute10,
      this.recorded = false,
      this.label,
      this.color,
      this.isFromCalendar = false,
      this.calendarEventId});
}
