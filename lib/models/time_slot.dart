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

  TimeSlot({
    required this.hour,
    required this.minute10,
    this.recorded = false,
    this.label,
    this.categoryId,
    this.color,
    this.isFromCalendar = false,
    this.calendarEventId,
  });
}
