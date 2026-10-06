import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../models/target.dart';
import '../models/target_progress.dart';
import '../services/target_progress_calculator.dart';
import 'target_calendar_day.dart';
import 'target_progress_indicator.dart';
import 'target_day_refresh.dart';
import '../providers/time_provider.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class TargetStatsSection extends StatefulWidget {
  final Target target;
  final TimeProvider provider;

  const TargetStatsSection({
    super.key,
    required this.target,
    required this.provider,
  });

  @override
  State<TargetStatsSection> createState() => _TargetStatsSectionState();
}

class _TargetStatsSectionState extends State<TargetStatsSection> {
  final ScrollController _calendarScrollController = ScrollController();
  final ScrollController _frequencyScrollController = ScrollController();

  // 365 天循环计算结果的缓存：依赖目标数据（revision 递增时失效），
  // 避免每次 build/notify 都重跑遍历
  int _statsRevision = -1;
  DateTime? _cachedToday;
  String? _cachedTargetId;
  DateTime? _cachedLatestMonth;
  List<_StreakData>? _cachedStreaks;
  Map<int, int>? _cachedWeekdayStats;

  /// 频率图矩阵：weekday → 最近 12 个月的完成次数（与 _cachedWeekdayStats 同步失效）
  Map<int, List<int>>? _cachedFrequencyMatrix;

  bool get _statsStale =>
      _cachedToday != TargetProgressCalculator.day(DateTime.now()) ||
      _cachedTargetId != widget.target.id ||
      provider.targetStatsCache.revision != _statsRevision;

  /// 数据变化时重算全部 365 天统计，否则复用缓存
  void _maybeRefreshStats() {
    if (!_statsStale) return;
    _cachedToday = TargetProgressCalculator.day(DateTime.now());
    _statsRevision = provider.targetStatsCache.revision;
    _cachedTargetId = widget.target.id;
    _cachedLatestMonth = _computeLatestRecordMonth();
    _cachedStreaks = _computeStreaks();
    _cachedWeekdayStats = _computeWeekdayStats();
    _cachedFrequencyMatrix = _computeFrequencyMatrix();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_calendarScrollController.hasClients) {
        _calendarScrollController.jumpTo(
          _calendarScrollController.position.maxScrollExtent,
        );
      }
      if (_frequencyScrollController.hasClients) {
        _frequencyScrollController.jumpTo(
          _frequencyScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  @override
  void dispose() {
    _calendarScrollController.dispose();
    _frequencyScrollController.dispose();
    super.dispose();
  }

  Target get target => widget.target;
  TimeProvider get provider => widget.provider;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return TargetDayRefresh(
        builder: (context) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                    padding: AppSpacing.page,
                    child: _buildGoalSection(colorScheme)),
                const SizedBox(height: 16),
                Padding(
                    padding: AppSpacing.page,
                    child: _buildPerformanceChart(colorScheme)),
                const SizedBox(height: 16),
                Padding(
                    padding: AppSpacing.page,
                    child: _buildHistoryChart(colorScheme)),
                const SizedBox(height: 16),
                _buildCalendarHeatmap(context, colorScheme),
                const SizedBox(height: 16),
                Padding(
                    padding: AppSpacing.page,
                    child: _buildStreakSection(colorScheme)),
                const SizedBox(height: 16),
                Padding(
                    padding: AppSpacing.page,
                    child: _buildFrequencyChart(colorScheme)),
              ],
            ));
  }

  // --- 通用方法 ---

  String _dateKey(DateTime date) =>
      "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";

  bool _isTargetCompletedOnDate(Target target, DateTime date) {
    final progress = provider.getTargetDayProgress(target, date);
    return progress.recordOnly ? progress.hasRecords : progress.isAchieved;
  }

  double _getTargetCountOnDate(Target target, DateTime date) =>
      provider.getTargetValueOnDate(target, date);

  double _getTargetCompletionCountInRange(
      Target target, DateTime start, DateTime end) {
    var total = 0.0;
    for (var date = start;
        date.isBefore(end);
        date = TargetProgressCalculator.nextDay(date)) {
      total += _getTargetCountOnDate(target, date);
    }
    return total;
  }

  double _getTimePointOnTimeRate(Target target, DateTime start, DateTime end) =>
      provider.getTargetAchievementRate(target, start, end);

  Widget _buildGoalSection(ColorScheme colorScheme) {
    final now = DateTime.now();
    final today = TargetProgressCalculator.day(now);
    final startOfWeek =
        DateTime(today.year, today.month, today.day - today.weekday + 1);
    final startOfMonth = DateTime(today.year, today.month, 1);
    final quarter = (today.month - 1) ~/ 3;
    final startOfQuarter = DateTime(today.year, quarter * 3 + 1, 1);
    final startOfYear = DateTime(today.year, 1, 1);
    final progress = provider.getTargetProgress(target);
    final end = TargetProgressCalculator.nextDay(today);
    return Card(
      child: Padding(
        padding: AppSpacing.cardComfortable,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('目标', style: AppText.sectionTitle),
            const SizedBox(height: AppSpacing.md),
            TargetProgressIndicator(progress: progress, showTodayLabel: true),
            const SizedBox(height: AppSpacing.sm),
            Text(progress.periodLabel, style: AppText.caption),
            const SizedBox(height: AppSpacing.md),
            if (target.type == TargetType.timePoint) ...[
              const Text('准时率（仅统计有记录的日期）', style: AppText.caption),
              _buildRateRow(
                  '周', _getTimePointOnTimeRate(target, startOfWeek, end)),
              _buildRateRow(
                  '月', _getTimePointOnTimeRate(target, startOfMonth, end)),
              _buildRateRow(
                  '季度', _getTimePointOnTimeRate(target, startOfQuarter, end)),
              _buildRateRow(
                  '年', _getTimePointOnTimeRate(target, startOfYear, end)),
            ] else ...[
              _buildRecordSummary('今日记录', _getTargetCountOnDate(target, today)),
              _buildRecordSummary('本周记录',
                  _getTargetCompletionCountInRange(target, startOfWeek, end)),
              _buildRecordSummary('本月记录',
                  _getTargetCompletionCountInRange(target, startOfMonth, end)),
              _buildRecordSummary('本年记录',
                  _getTargetCompletionCountInRange(target, startOfYear, end)),
              if (target.compareType == '少于' || target.compareType == '等于')
                const Text('周期结束前显示当前状态，结束后判定最终是否达标。', style: AppText.caption),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRecordSummary(String label, double value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(children: [
          Expanded(child: Text(label, style: AppText.caption)),
          Text(
              '${TargetProgress.number(value)} ${target.type == TargetType.frequency ? '次' : '小时'}',
              style: AppText.body),
        ]),
      );

  Widget _buildRateRow(String label, double rate) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label, style: AppText.caption)),
            Text('${(rate * 100).round()}%', style: AppText.caption),
          ]),
          const SizedBox(height: AppSpacing.xs),
          LinearProgressIndicator(
              value: rate,
              color:
                  context.wallpaperFill(Theme.of(context).colorScheme.primary),
              backgroundColor: context.wallpaperFill(
                  Theme.of(context).colorScheme.surfaceContainerHighest)),
        ]),
      );

  // --- 成绩折线图 ---

  Widget _buildPerformanceChart(ColorScheme colorScheme) {
    final now = DateTime.now();
    final monthlyStats = <String, double>{};

    for (int i = 11; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final nextMonth = DateTime(now.year, now.month - i + 1, 1);
      final key = "${month.year}-${month.month.toString().padLeft(2, '0')}";

      monthlyStats[key] =
          provider.getTargetAchievementRate(target, month, nextMonth) * 100;
    }

    final spots = <FlSpot>[];
    final labels = <String>[];
    var index = 0;

    monthlyStats.forEach((key, value) {
      spots.add(FlSpot(index.toDouble(), value));
      labels.add(key.substring(5));
      index++;
    });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                const Text('周期达标率', style: AppText.sectionTitle),
                Text(
                    target.compareType == '少于' || target.compareType == '等于'
                        ? '已结束且有记录的周期'
                        : '有记录的周期',
                    style: AppText.caption),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: 20,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) {
                          return Text('${value.toInt()}%',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: colorScheme.onSurfaceVariant));
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx >= 0 && idx < labels.length) {
                            return Text(labels[idx],
                                style: TextStyle(
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant));
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => colorScheme.inverseSurface,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          return LineTooltipItem(
                            '${spot.y.toStringAsFixed(2)}%',
                            TextStyle(
                              color: colorScheme.onInverseSurface,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: colorScheme.primary,
                      barWidth: 3,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) {
                          return FlDotCirclePainter(
                            radius: 4,
                            color: colorScheme.primary,
                            strokeWidth: 2,
                            strokeColor: colorScheme.surface,
                          );
                        },
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: colorScheme.primary.withValues(alpha: 0.1),
                      ),
                    ),
                  ],
                  minY: 0,
                  maxY: 100,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- 历史柱状图 ---

  Widget _buildHistoryChart(ColorScheme colorScheme) {
    final now = DateTime.now();
    final monthlyStats = <String, double>{};

    for (int i = 11; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final nextMonth = DateTime(now.year, now.month - i + 1, 1);
      final key = "${month.year}-${month.month.toString().padLeft(2, '0')}";

      if (target.type == TargetType.timePoint) {
        monthlyStats[key] =
            _getTimePointOnTimeRate(target, month, nextMonth) * 100;
      } else {
        monthlyStats[key] =
            _getTargetCompletionCountInRange(target, month, nextMonth);
      }
    }

    final bars = <BarChartGroupData>[];
    final labels = <String>[];
    var index = 0;
    var maxValue = 0.0;

    monthlyStats.forEach((key, value) {
      bars.add(BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: value,
            color: colorScheme.primary,
            width: 20,
            borderRadius: const BorderRadius.vertical(top: AppRadius.rGrid),
          ),
        ],
      ));
      labels.add(key.substring(5));
      if (value > maxValue) maxValue = value;
      index++;
    });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('历史',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary)),
                Text('月',
                    style: TextStyle(
                        fontSize: 14, color: colorScheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxValue > 0 ? (maxValue * 1.2) : 10,
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => colorScheme.inverseSurface,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final displayValue = target.type == TargetType.timePoint
                            ? '${rod.toY.toStringAsFixed(1)}%'
                            : target.type == TargetType.duration
                                ? '${rod.toY.toStringAsFixed(1)}h'
                                : '${rod.toY.toInt()}';
                        return BarTooltipItem(
                          displayValue,
                          TextStyle(
                              color: colorScheme.onInverseSurface,
                              fontWeight: FontWeight.bold),
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx >= 0 && idx < labels.length) {
                            return Text(labels[idx],
                                style: TextStyle(
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant));
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                    leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  gridData: const FlGridData(show: false),
                  barGroups: bars,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- 日历热力图 ---

  DateTime? _computeLatestRecordMonth() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    for (int i = 0; i < 365; i++) {
      final date = today.subtract(Duration(days: i));
      if (provider.getTargetDayProgress(target, date).hasRecords) {
        return DateTime(date.year, date.month, 1);
      }
    }
    return null;
  }

  Widget _buildCalendarHeatmap(BuildContext context, ColorScheme colorScheme) {
    final now = DateTime.now();
    final startMonth = DateTime(now.year, now.month - 5, 1);
    final progress = provider.getTargetProgress(target);
    final legend = target.type == TargetType.timePoint
        ? '勾号：符合条件；感叹号：未达标；空白：未记录。'
        : !progress.period.isDaily
            ? '高亮表示当天有记录；完整周期进度见目标卡片。'
            : target.compareType == '少于'
                ? '面积表示已用额度；达到上限或超限时显示警告。'
                : '面积表示记录量占目标值；勾号表示达标。点击日期查看明细。';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
              padding: AppSpacing.page,
              child: Text('日历', style: AppText.sectionTitle)),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(builder: (context, constraints) {
            final scale = math.max(
                1.0,
                MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) /
                    AppText.body.fontSize!);
            final minWidth = AppSizes.targetCalendarMonthMinWidth * scale;
            final visibleMonths =
                (constraints.maxWidth / (minWidth + AppSpacing.lg))
                    .floor()
                    .clamp(1, 3);
            final monthWidth = math.max(
                minWidth,
                (constraints.maxWidth - AppSpacing.lg * (visibleMonths - 1)) /
                    visibleMonths);
            final today = TargetProgressCalculator.day(now);
            final behavior = ScrollConfiguration.of(context);
            return ScrollConfiguration(
              behavior: behavior.copyWith(dragDevices: {
                ...behavior.dragDevices,
                PointerDeviceKind.mouse
              }),
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: SingleChildScrollView(
                  controller: _calendarScrollController,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var index = 0; index < 6; index++) ...[
                          if (index > 0) const SizedBox(width: AppSpacing.lg),
                          _buildMonthCalendar(
                              DateTime(
                                  startMonth.year, startMonth.month + index, 1),
                              today,
                              monthWidth),
                        ],
                      ]),
                ),
              ),
            );
          }),
          const SizedBox(height: AppSpacing.sm),
          Padding(
              padding: AppSpacing.page,
              child: Text(legend, style: AppText.caption)),
        ]),
      ),
    );
  }

  Widget _buildMonthCalendar(DateTime month, DateTime today, double width) {
    final days = DateTime(month.year, month.month + 1, 0).day;
    final firstWeekday = month.weekday;
    final cellWidth = width / 7;
    final scale =
        MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) /
            AppText.body.fontSize!;
    final cellHeight = AppSizes.minTapTarget * math.max(1.0, scale);
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return SizedBox(
        width: width,
        child: Column(children: [
          Text('${month.year}年${month.month}月', style: AppText.body),
          const SizedBox(height: AppSpacing.sm),
          Row(children: [
            for (final weekday in weekdays)
              SizedBox(
                  width: cellWidth,
                  child: Text(weekday,
                      textAlign: TextAlign.center, style: AppText.caption))
          ]),
          const SizedBox(height: AppSpacing.xs),
          for (var week = 0; week < 6; week++)
            Row(children: [
              for (var column = 0; column < 7; column++)
                Builder(builder: (context) {
                  final day = week * 7 + column - firstWeekday + 2;
                  final date = DateTime(month.year, month.month, day);
                  return SizedBox(
                      width: cellWidth,
                      height: cellHeight,
                      child: day < 1 || day > days
                          ? null
                          : TargetCalendarDay(
                              key: ValueKey(
                                  'target-day-${target.id}-${_dateKey(date)}'),
                              date: date,
                              progress:
                                  provider.getTargetDayProgress(target, date),
                              isToday: date == today,
                              onTap: () => showTargetDayDetails(
                                  context, provider, target, date),
                            ));
                }),
            ]),
        ]));
  }

  // --- 连续记录 ---

  Widget _buildStreakSection(ColorScheme colorScheme) {
    final streaks = _calculateStreaks();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                provider.getTargetProgress(target).period.isDaily
                    ? '最佳连续达标天数'
                    : '最佳连续记录天数',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary)),
            const SizedBox(height: 12),
            if (streaks.isEmpty)
              Text('暂无连续记录',
                  style: TextStyle(color: colorScheme.onSurfaceVariant))
            else
              ...streaks.take(5).map((streak) {
                final maxDays = streaks.first.days;
                final progress = maxDays > 0 ? streak.days / maxDays : 0.0;
                final barColor = streak.days >= 7
                    ? colorScheme.primary
                    : colorScheme.secondary;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 60,
                        child: Text(
                          DateFormat('M/d').format(streak.startDate),
                          style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          children: [
                            Container(
                              height: 24,
                              decoration: BoxDecoration(
                                color: context.wallpaperFill(
                                    colorScheme.surfaceContainerHighest),
                                borderRadius: AppRadius.gridAll,
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: progress,
                              child: Container(
                                height: 24,
                                decoration: BoxDecoration(
                                  color: barColor,
                                  borderRadius: AppRadius.gridAll,
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: Center(
                                child: Text(
                                  '${streak.days}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: progress > 0.3
                                        ? AppSemanticColors.onColor(barColor)
                                        : colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 60,
                        child: Text(
                          DateFormat('M/d').format(streak.endDate),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  List<_StreakData> _calculateStreaks() {
    _maybeRefreshStats();
    return _cachedStreaks!;
  }

  List<_StreakData> _computeStreaks() {
    final now = DateTime.now();
    final completionDates = <DateTime>{};

    for (int i = 0; i < 365; i++) {
      final date = DateTime(now.year, now.month, now.day - i);
      if (_isTargetCompletedOnDate(target, date)) {
        completionDates.add(date);
      }
    }

    if (completionDates.isEmpty) return [];

    final sortedDates = completionDates.toList()
      ..sort((a, b) => a.compareTo(b));
    final streaks = <_StreakData>[];

    var streakStart = sortedDates[0];
    var streakEnd = sortedDates[0];
    var streakDays = 1;

    for (int i = 1; i < sortedDates.length; i++) {
      if (sortedDates[i] == TargetProgressCalculator.nextDay(streakEnd)) {
        streakEnd = sortedDates[i];
        streakDays++;
      } else {
        if (streakDays > 1) {
          streaks.add(_StreakData(
            startDate: streakStart,
            endDate: streakEnd,
            days: streakDays,
          ));
        }
        streakStart = sortedDates[i];
        streakEnd = sortedDates[i];
        streakDays = 1;
      }
    }

    if (streakDays > 1) {
      streaks.add(_StreakData(
        startDate: streakStart,
        endDate: streakEnd,
        days: streakDays,
      ));
    }

    streaks.sort((a, b) => b.days.compareTo(a.days));
    return streaks;
  }

  // --- 频率气泡图 ---

  Map<int, int> _computeWeekdayStats() {
    final now = DateTime.now();
    final weekdayStats = <int, int>{1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0};

    for (int i = 0; i < 365; i++) {
      final date = DateTime(now.year, now.month, now.day - i);
      if (_isTargetCompletedOnDate(target, date)) {
        weekdayStats[date.weekday] = (weekdayStats[date.weekday] ?? 0) + 1;
      }
    }
    return weekdayStats;
  }

  /// 频率图数据：行 = 有记录的那几个星期几，列 = 最近 12 个月。
  ///
  /// 原先在 build 里现算（7 星期 × 12 月 × 逐日），随 build/滚动反复重跑；
  /// 现在与其它 365 天统计一起缓存，仅在 revision 变化时重算。
  Map<int, List<int>> _computeFrequencyMatrix() {
    final weekdayStats = _cachedWeekdayStats ?? const <int, int>{};
    final now = DateTime.now();
    final endMonth = _cachedLatestMonth ?? DateTime(now.year, now.month, 1);
    final matrix = <int, List<int>>{};
    for (final weekday in weekdayStats.keys) {
      final row = <int>[];
      for (var monthIndex = 0; monthIndex < 12; monthIndex++) {
        final offset = 11 - monthIndex;
        final month = DateTime(endMonth.year, endMonth.month - offset, 1);
        final monthEnd =
            DateTime(endMonth.year, endMonth.month - offset + 1, 0);
        var count = 0;
        for (var d = month;
            !d.isAfter(monthEnd);
            d = TargetProgressCalculator.nextDay(d)) {
          if (d.weekday != weekday) continue;
          if (_isTargetCompletedOnDate(target, d)) count++;
        }
        row.add(count);
      }
      matrix[weekday] = row;
    }
    return matrix;
  }

  Widget _buildFrequencyChart(ColorScheme colorScheme) {
    _maybeRefreshStats();
    final now = DateTime.now();
    // 以最新记录月为 12 个月窗口终点；无记录时用当前月
    final endMonth = _cachedLatestMonth ?? DateTime(now.year, now.month, 1);
    final frequencyMatrix = _cachedFrequencyMatrix!;

    final dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    final monthLabels = <String>[];
    for (int i = 11; i >= 0; i--) {
      final month = DateTime(endMonth.year, endMonth.month - i, 1);
      monthLabels.add('${month.month}月');
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                provider.getTargetProgress(target).period.isDaily
                    ? '达标日期分布'
                    : '记录日期分布',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary)),
            const SizedBox(height: 12),
            Row(
              children: [
                Column(
                  children: [
                    const SizedBox(height: 18),
                    ...List.generate(
                        7,
                        (i) => Container(
                              height: 24,
                              width: 36,
                              alignment: Alignment.centerRight,
                              child: Text(dayNames[i + 1],
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: colorScheme.onSurfaceVariant)),
                            )),
                  ],
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _frequencyScrollController,
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: monthLabels
                              .map((label) => SizedBox(
                                    width: 30,
                                    child: Text(
                                      label,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          fontSize: 9,
                                          color: colorScheme.onSurfaceVariant),
                                    ),
                                  ))
                              .toList(),
                        ),
                        const SizedBox(height: 4),
                        ...frequencyMatrix.entries.map((entry) {
                          return Row(
                            children: List.generate(12, (monthIndex) {
                              final monthWeekdayCount = entry.value[monthIndex];

                              final monthProgress = monthWeekdayCount > 0
                                  ? (monthWeekdayCount / 5).clamp(0.0, 1.0)
                                  : 0.0;
                              final size = 6.0 + (monthProgress * 14);

                              return SizedBox(
                                width: 30,
                                height: 24,
                                child: Center(
                                  child: monthProgress > 0
                                      ? Container(
                                          width: size,
                                          height: size,
                                          decoration: BoxDecoration(
                                            color: colorScheme.primary
                                                .withValues(
                                                    alpha: 0.3 +
                                                        monthProgress * 0.7),
                                            shape: BoxShape.circle,
                                          ),
                                        )
                                      : const SizedBox(width: 6, height: 6),
                                ),
                              );
                            }),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StreakData {
  final DateTime startDate;
  final DateTime endDate;
  final int days;

  const _StreakData({
    required this.startDate,
    required this.endDate,
    required this.days,
  });
}
