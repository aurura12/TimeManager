import 'package:flutter/material.dart';

class TimeSlot {
  final int hour;
  final int minute10;
  bool recorded;
  String? label; // 记录的名称，如“语言”
  Color? color; // 对应的颜色

  TimeSlot(
      {required this.hour,
      required this.minute10,
      this.recorded = false,
      this.label,
      this.color});
}
