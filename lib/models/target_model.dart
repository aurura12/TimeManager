import 'package:flutter/material.dart';

enum TargetPeriod { daily, weekly, monthly, yearly }

class TargetItem {
  final String title;
  final String? subtitle; // 例如 "每周"、"每月"
  final String progressText;
  final double progressPercent; // 0.0 到 1.0
  final Color themeColor;
  final VoidCallback? onTap;

  TargetItem({
    required this.title,
    this.subtitle,
    required this.progressText,
    this.progressPercent = 0.0,
    required this.themeColor,
    this.onTap,
  });
}
