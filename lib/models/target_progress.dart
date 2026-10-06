import 'target.dart';

/// 日期范围含开始日，不含结束日。
class TargetPeriodRange {
  const TargetPeriodRange({
    required this.start,
    required this.end,
    this.isValid = true,
  });

  final DateTime start;
  final DateTime end;
  final bool isValid;

  bool get isDaily => end == DateTime(start.year, start.month, start.day + 1);
  bool contains(DateTime date) => !date.isBefore(start) && date.isBefore(end);
  bool isFinishedAt(DateTime now) => !now.isBefore(end);
}

enum TargetProgressStatus {
  notRecorded,
  inProgress,
  reachedValue,
  achieved,
  withinLimit,
  limitReached,
  exceeded,
  missed,
  provisional,
  notStarted,
  outsidePeriod,
  invalid,
}

/// 计算结果只存在内存中；完成状态随记录和目标条件重新计算。
class TargetProgress {
  const TargetProgress({
    required this.target,
    required this.period,
    required this.value,
    required this.goal,
    required this.hasRecords,
    required this.status,
    this.firstMinute,
    this.recordOnly = false,
  });

  final Target target;
  final TargetPeriodRange period;
  final double value;
  final double goal;
  final bool hasRecords;
  final TargetProgressStatus status;
  final int? firstMinute;

  /// 多日目标的日期格只表示当天记录，不把周期配额摊成每日要求。
  final bool recordOnly;

  double get ratio => goal > 0 ? (value / goal).clamp(0.0, 1.0) : 0;
  bool get isAchieved => status == TargetProgressStatus.achieved;
  bool get isWarning => switch (status) {
        TargetProgressStatus.limitReached ||
        TargetProgressStatus.exceeded ||
        TargetProgressStatus.missed ||
        TargetProgressStatus.invalid =>
          true,
        _ => false,
      };

  String get unit => target.type == TargetType.frequency ? '次' : '小时';
  static String number(double value) =>
      value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  String get statusLabel {
    if (recordOnly &&
        status != TargetProgressStatus.outsidePeriod &&
        status != TargetProgressStatus.invalid) {
      return hasRecords ? '有记录' : '未记录';
    }
    return switch (status) {
      TargetProgressStatus.notRecorded => '未记录',
      TargetProgressStatus.inProgress => '未达目标',
      TargetProgressStatus.reachedValue => '达到数值，尚未超过',
      TargetProgressStatus.achieved =>
        target.type == TargetType.timePoint ? '准时' : '已达目标',
      TargetProgressStatus.withinLimit => '暂未超限',
      TargetProgressStatus.limitReached => '达到上限',
      TargetProgressStatus.exceeded =>
        target.compareType == '少于' ? '已超限' : '已超过目标',
      TargetProgressStatus.missed => '未达标',
      TargetProgressStatus.provisional => '暂时达标',
      TargetProgressStatus.notStarted => '尚未开始',
      TargetProgressStatus.outsidePeriod => '不在目标日期内',
      TargetProgressStatus.invalid => '请检查目标设置',
    };
  }

  String get valueLabel {
    if (target.type == TargetType.timePoint) {
      final minute = firstMinute;
      if (minute == null) return '尚无有效时间记录';
      return '首次记录 ${twoDigits(minute ~/ 60)}:${twoDigits(minute % 60)}';
    }
    if (recordOnly) return '${number(value)} $unit';
    if (target.compareType == '少于') {
      return '已用 ${number(value)} / 上限 ${number(goal)} $unit';
    }
    return '${number(value)} / ${number(goal)} $unit';
  }

  static String twoDigits(int value) => value.toString().padLeft(2, '0');
  static String dateLabel(DateTime date) =>
      '${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)}';
  String get periodLabel =>
      '${dateLabel(period.start)} ～ ${dateLabel(DateTime(period.end.year, period.end.month, period.end.day - 1))}';
}
