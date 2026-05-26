import 'package:flutter/material.dart';

class SearchRecordEntry {
  final String label;
  final String timeRange;
  final Color? color;
  final int durationMinutes;

  const SearchRecordEntry({
    required this.label,
    required this.timeRange,
    this.color,
    required this.durationMinutes,
  });
}

class SearchRecordGroup {
  final DateTime date;
  final List<SearchRecordEntry> entries;

  const SearchRecordGroup({
    required this.date,
    required this.entries,
  });

  int get totalMinutes =>
      entries.fold(0, (sum, e) => sum + e.durationMinutes);
}
