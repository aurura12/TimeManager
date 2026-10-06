import 'dart:math' as math;

import '../models/target.dart';
import '../models/target_progress.dart';

/// 各端共用的周期和比较规则，不依赖 UI 或持久化。
abstract final class TargetProgressCalculator {
  static DateTime day(DateTime date) =>
      DateTime(date.year, date.month, date.day);
  static DateTime nextDay(DateTime date) =>
      DateTime(date.year, date.month, date.day + 1);

  static DateTime _addMonths(DateTime date, int months) {
    final month = DateTime(date.year, date.month + months, 1);
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    return DateTime(month.year, month.month, math.min(date.day, lastDay));
  }

  static DateTime _creationDay(Target target, DateTime fallback) {
    final timestamp = int.tryParse(target.id);
    if (timestamp != null && timestamp > 0 && timestamp < 8640000000000000) {
      return day(DateTime.fromMillisecondsSinceEpoch(timestamp));
    }
    // 历史导入的非时间戳 ID 沿用参考日，避免整条目标无法展示。
    return fallback;
  }

  static DateTime? _parseDate(String input) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(input)) return null;
    final date = DateTime.tryParse(input);
    return date != null && TargetProgress.dateLabel(date) == input
        ? date
        : null;
  }

  static bool isRepeating(Target target) =>
      target.type == TargetType.timePoint ||
      const ['每天', '每周', '每月', '每年'].contains(target.period) ||
      RegExp(r'^每\d+天$').hasMatch(target.period);

  static TargetPeriodRange periodFor(Target target, DateTime reference) {
    final date = day(reference);
    final anchor = _creationDay(target, date);
    var start = date;
    var end = nextDay(date);
    var valid = true;
    if (target.type != TargetType.timePoint) {
      switch (target.period) {
        case '每天':
          break;
        case '今天':
          start = anchor;
          end = nextDay(start);
        case '每周' || '本周':
          final base = target.period == '本周' ? anchor : date;
          start = DateTime(base.year, base.month, base.day - base.weekday + 1);
          end = DateTime(start.year, start.month, start.day + 7);
        case '每月' || '本月':
          final base = target.period == '本月' ? anchor : date;
          start = DateTime(base.year, base.month, 1);
          end = DateTime(base.year, base.month + 1, 1);
        case '每年' || '今年':
          final base = target.period == '今年' ? anchor : date;
          start = DateTime(base.year, 1, 1);
          end = DateTime(base.year + 1, 1, 1);
        case '一周内':
          start = anchor;
          end = DateTime(start.year, start.month, start.day + 7);
        case '一月内':
          start = anchor;
          end = _addMonths(start, 1);
        case '一年内':
          start = anchor;
          end = _addMonths(start, 12);
        default:
          final repeating = RegExp(r'^每(\d+)天$').firstMatch(target.period);
          final once = RegExp(r'^(\d+)天内$').firstMatch(target.period);
          if (repeating != null || once != null) {
            final days = int.tryParse((repeating ?? once)!.group(1)!);
            valid = days != null && days > 0 && days <= 36600;
            if (valid) {
              final difference = DateTime.utc(date.year, date.month, date.day)
                  .difference(
                      DateTime.utc(anchor.year, anchor.month, anchor.day))
                  .inDays;
              final cycle =
                  repeating == null || difference < 0 ? 0 : difference ~/ days;
              start = DateTime(
                  anchor.year, anchor.month, anchor.day + cycle * days);
              end = DateTime(start.year, start.month, start.day + days);
            }
          } else {
            final parts = target.period.split('~');
            final first = parts.length == 2 ? _parseDate(parts.first) : null;
            final last = parts.length == 2 ? _parseDate(parts.last) : null;
            valid = first != null && last != null && !last.isBefore(first);
            if (valid) {
              start = day(first);
              end = nextDay(last);
            }
          }
      }
    }
    return TargetPeriodRange(start: start, end: end, isValid: valid);
  }

  static Iterable<TargetPeriodRange> periodsInRange(
    Target target,
    DateTime start,
    DateTime end,
  ) sync* {
    var cursor = day(start);
    while (cursor.isBefore(end)) {
      final period = periodFor(target, cursor);
      if (!period.isValid) return;
      if (period.end.isAfter(start) && period.start.isBefore(end)) yield period;
      if (!isRepeating(target)) return;
      cursor = period.end.isAfter(cursor) ? period.end : nextDay(cursor);
    }
  }

  static TargetProgress evaluate({
    required Target target,
    required TargetPeriodRange period,
    required double value,
    required bool hasRecords,
    required DateTime now,
    int? firstMinute,
  }) {
    final goal = switch (target.type) {
      TargetType.duration => target.durationHours,
      TargetType.frequency => target.frequencyCount.toDouble(),
      TargetType.timePoint => 1.0,
    };
    TargetProgressStatus status;
    if (!period.isValid || !goal.isFinite || goal <= 0 || !value.isFinite) {
      status = TargetProgressStatus.invalid;
    } else if (now.isBefore(period.start)) {
      status = TargetProgressStatus.notStarted;
    } else if (!hasRecords) {
      status = TargetProgressStatus.notRecorded;
    } else if (target.type == TargetType.timePoint) {
      status = value > 0
          ? TargetProgressStatus.achieved
          : TargetProgressStatus.missed;
    } else {
      final equal = (value - goal).abs() < 1e-8;
      final finished = period.isFinishedAt(now);
      status = switch (target.compareType) {
        '少于' => equal
            ? TargetProgressStatus.limitReached
            : value > goal
                ? TargetProgressStatus.exceeded
                : finished
                    ? TargetProgressStatus.achieved
                    : TargetProgressStatus.withinLimit,
        '等于' => equal
            ? finished
                ? TargetProgressStatus.achieved
                : TargetProgressStatus.provisional
            : value > goal
                ? TargetProgressStatus.exceeded
                : TargetProgressStatus.inProgress,
        '至少' || '达到' => value > goal || equal
            ? TargetProgressStatus.achieved
            : TargetProgressStatus.inProgress,
        '超过' => equal
            ? TargetProgressStatus.reachedValue
            : value > goal
                ? TargetProgressStatus.achieved
                : TargetProgressStatus.inProgress,
        _ => TargetProgressStatus.invalid,
      };
    }
    return TargetProgress(
      target: target,
      period: period,
      value: value,
      goal: goal,
      hasRecords: hasRecords,
      status: status,
      firstMinute: firstMinute,
    );
  }
}
