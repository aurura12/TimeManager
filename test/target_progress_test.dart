import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/models/target_progress.dart';
import 'package:time_manager/services/target_progress_calculator.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';

Target _target({
  TargetType type = TargetType.duration,
  String comparison = '至少',
  String period = '每天',
  DateTime? created,
}) =>
    Target(
      id: (created ?? DateTime(2026, 10, 1)).millisecondsSinceEpoch.toString(),
      name: '学习',
      type: type,
      color: AppSemanticColors.brand,
      period: period,
      compareType: comparison,
      durationHours: 5,
      frequencyCount: 3,
    );

void main() {
  final date = DateTime(2026, 10, 6);
  final now = DateTime(2026, 10, 6, 12);
  TargetProgress evaluate(Target target, double value,
          {DateTime? clock, bool recorded = true}) =>
      TargetProgressCalculator.evaluate(
        target: target,
        period: TargetProgressCalculator.periodFor(target, date),
        value: value,
        hasRecords: recorded,
        now: clock ?? now,
      );

  test('至少目标区分未记录、部分完成、刚好达到和超额', () {
    final target = _target();
    expect(evaluate(target, 0, recorded: false).status,
        TargetProgressStatus.notRecorded);
    final partial = evaluate(target, 2);
    expect(partial.ratio, closeTo(0.4, 1e-8));
    expect(partial.isAchieved, isFalse);
    expect(evaluate(target, 5).isAchieved, isTrue);
    expect(evaluate(target, 6).ratio, 1);
    expect(evaluate(target, 6).value, 6);
  });

  test('超过目标到100%仍要区分刚好达到和真正超过', () {
    final target = _target(comparison: '超过');
    final equal = evaluate(target, 5);
    expect(equal.ratio, 1);
    expect(equal.status, TargetProgressStatus.reachedValue);
    expect(equal.isAchieved, isFalse);
    expect(evaluate(target, 5 + 1 / 6).isAchieved, isTrue);
  });

  test('等于目标先暂时达标，结束后确认，超额立即警告', () {
    final target = _target(comparison: '等于');
    expect(evaluate(target, 5).status, TargetProgressStatus.provisional);
    expect(
        evaluate(target, 5, clock: DateTime(2026, 10, 7)).isAchieved, isTrue);
    expect(evaluate(target, 6).status, TargetProgressStatus.exceeded);
  });

  test('少于目标显示占用，边界警告，无记录不自动判成功', () {
    final target = _target(comparison: '少于');
    expect(evaluate(target, 2).status, TargetProgressStatus.withinLimit);
    expect(evaluate(target, 2).ratio, 0.4);
    expect(evaluate(target, 5).status, TargetProgressStatus.limitReached);
    expect(evaluate(target, 6).status, TargetProgressStatus.exceeded);
    expect(
        evaluate(target, 2, clock: DateTime(2026, 10, 7)).isAchieved, isTrue);
    expect(
        evaluate(target, 0, recorded: false, clock: DateTime(2026, 10, 7))
            .isAchieved,
        isFalse);
  });

  test('次数目标使用独立配额，至少条件能经JSON同步', () {
    final target =
        Target.fromJson(_target(type: TargetType.frequency).toJson());
    expect(target.compareType, '至少');
    expect(evaluate(target, 1).ratio, closeTo(1 / 3, 1e-8));
    expect(evaluate(target, 3).isAchieved, isTrue);
  });

  test('自然日周月年与每N天的周期边界', () {
    final cases = <String, (DateTime, DateTime)>{
      '每天': (DateTime(2026, 10, 6), DateTime(2026, 10, 7)),
      '每周': (DateTime(2026, 10, 5), DateTime(2026, 10, 12)),
      '每月': (DateTime(2026, 10, 1), DateTime(2026, 11, 1)),
      '每年': (DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
      '每3天': (DateTime(2026, 10, 4), DateTime(2026, 10, 7)),
    };
    for (final entry in cases.entries) {
      final period =
          TargetProgressCalculator.periodFor(_target(period: entry.key), date);
      expect((period.start, period.end), entry.value, reason: entry.key);
    }
  });

  test('一次性周期保留创建日起点，起止日期含最后一天', () {
    final cases = <String, (DateTime, DateTime)>{
      '今天': (DateTime(2026, 10, 1), DateTime(2026, 10, 2)),
      '本周': (DateTime(2026, 9, 28), DateTime(2026, 10, 5)),
      '本月': (DateTime(2026, 10, 1), DateTime(2026, 11, 1)),
      '今年': (DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
      '一周内': (DateTime(2026, 10, 1), DateTime(2026, 10, 8)),
      '一月内': (DateTime(2026, 10, 1), DateTime(2026, 11, 1)),
      '一年内': (DateTime(2026, 10, 1), DateTime(2027, 10, 1)),
      '3天内': (DateTime(2026, 10, 1), DateTime(2026, 10, 4)),
      '2026-10-04~2026-10-06': (DateTime(2026, 10, 4), DateTime(2026, 10, 7)),
    };
    for (final entry in cases.entries) {
      final period =
          TargetProgressCalculator.periodFor(_target(period: entry.key), date);
      expect((period.start, period.end), entry.value, reason: entry.key);
    }
  });

  test('相对月和年在月底闰年钳制日期，不溢出到下一个月', () {
    final month = TargetProgressCalculator.periodFor(
        _target(period: '一月内', created: DateTime(2026, 1, 31)), date);
    expect(month.end, DateTime(2026, 2, 28));
    final year = TargetProgressCalculator.periodFor(
        _target(period: '一年内', created: DateTime(2024, 2, 29)), date);
    expect(year.end, DateTime(2025, 2, 28));
  });

  test('无效周期与未来周期不会误报完成', () {
    expect(evaluate(_target(period: '每0天'), 5).status,
        TargetProgressStatus.invalid);
    expect(evaluate(_target(period: '2026-10-07~2026-10-09'), 5).status,
        TargetProgressStatus.notStarted);
    expect(evaluate(_target(period: '2026-02-30~2026-03-05'), 5).status,
        TargetProgressStatus.invalid);
  });
}
