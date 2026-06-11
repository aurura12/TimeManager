import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../models/target.dart';
import '../providers/time_provider.dart';

class TargetStatsSection extends StatelessWidget {
  final Target target;
  final TimeProvider provider;

  const TargetStatsSection({
    super.key,
    required this.target,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildGoalSection(colorScheme),
        const SizedBox(height: 16),
        _buildPerformanceChart(colorScheme),
        const SizedBox(height: 16),
        _buildHistoryChart(colorScheme),
        const SizedBox(height: 16),
        _buildCalendarHeatmap(colorScheme),
        const SizedBox(height: 16),
        _buildStreakSection(colorScheme),
        const SizedBox(height: 16),
        _buildFrequencyChart(colorScheme),
      ],
    );
  }

  Widget _buildGoalSection(ColorScheme colorScheme) {
    final todayCount = provider.getTargetTodayCount(target);
    final weekCount = provider.getTargetWeekCount(target);
    final monthCount = provider.getTargetMonthCount(target);
    final quarterCount = provider.getTargetQuarterCount(target);
    final yearCount = provider.getTargetYearCount(target);

    final dailyGoal = provider.getTargetDailyGoal(target);
    final weeklyGoal = provider.getTargetWeeklyGoal(target);
    final monthlyGoal = provider.getTargetMonthlyGoal(target);
    final quarterlyGoal = provider.getTargetQuarterlyGoal(target);
    final yearlyGoal = provider.getTargetYearlyGoal(target);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('目标', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colorScheme.primary)),
            const SizedBox(height: 12),
            _buildProgressRow('今日', todayCount, dailyGoal, colorScheme),
            _buildProgressRow('周', weekCount, weeklyGoal, colorScheme),
            _buildProgressRow('月', monthCount, monthlyGoal, colorScheme),
            _buildProgressRow('季度', quarterCount, quarterlyGoal, colorScheme),
            _buildProgressRow('年', yearCount, yearlyGoal, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressRow(String label, int current, int goal, ColorScheme colorScheme) {
    final progress = goal > 0 ? (current / goal).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(label, style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  height: 24,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: progress,
                  child: Container(
                    height: 24,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Center(
                    child: Text(
                      '$current',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: progress > 0.5 ? Colors.white : colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 50,
            child: Text('$goal', style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant), textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceChart(ColorScheme colorScheme) {
    final monthlyStats = provider.getTargetMonthlyStats(target, months: 12);
    final monthlyGoal = provider.getTargetMonthlyGoal(target);

    final spots = <FlSpot>[];
    final labels = <String>[];
    var index = 0;

    monthlyStats.entries.toList().reversed.forEach((entry) {
      final percentage = monthlyGoal > 0 ? (entry.value / monthlyGoal * 100).clamp(0.0, 100.0) : 0.0;
      spots.add(FlSpot(index.toDouble(), percentage));
      labels.add(entry.key.substring(5));
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
                Text('成绩', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colorScheme.primary)),
                Text('年', style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant)),
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
                          return Text('${value.toInt()}%', style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant));
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
                            return Text(labels[idx], style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant));
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
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
                            strokeColor: Colors.white,
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

  Widget _buildHistoryChart(ColorScheme colorScheme) {
    final monthlyStats = provider.getTargetMonthlyStats(target, months: 12);

    final bars = <BarChartGroupData>[];
    final labels = <String>[];
    var index = 0;
    var maxValue = 0;

    monthlyStats.entries.toList().reversed.forEach((entry) {
      bars.add(BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: entry.value.toDouble(),
            color: colorScheme.primary,
            width: 20,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          ),
        ],
      ));
      labels.add(entry.key.substring(5));
      if (entry.value > maxValue) maxValue = entry.value;
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
                Text('历史', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colorScheme.primary)),
                Text('月', style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant)),
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
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        return BarTooltipItem(
                          '${rod.toY.toInt()}',
                          TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
                            return Text(labels[idx], style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant));
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                    leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
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

  Widget _buildCalendarHeatmap(ColorScheme colorScheme) {
    final completionDates = provider.getTargetCompletionDates(target);
    final now = DateTime.now();
    final startMonth = DateTime(now.year, now.month - 5, 1);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('日历', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colorScheme.primary)),
            const SizedBox(height: 16),
            _buildCalendarGrid(completionDates, startMonth, now, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarGrid(Set<DateTime> completionDates, DateTime startMonth, DateTime endMonth, ColorScheme colorScheme) {
    final weeks = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final months = <String>[];

    var current = startMonth;
    while (!current.isAfter(endMonth)) {
      months.add('${current.month}月');
      current = DateTime(current.year, current.month + 1, 1);
    }

    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 40),
            ...months.map((m) => Expanded(
              child: Text(m, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
            )),
          ],
        ),
        const SizedBox(height: 8),
        ...weeks.asMap().entries.map((entry) {
          final weekday = entry.key + 1;
          return Row(
            children: [
              SizedBox(
                width: 40,
                child: Text(entry.value, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
              ),
              ..._buildWeekRow(weekday, completionDates, startMonth, endMonth, colorScheme),
            ],
          );
        }),
      ],
    );
  }

  List<Widget> _buildWeekRow(int weekday, Set<DateTime> completionDates, DateTime startMonth, DateTime endMonth, ColorScheme colorScheme) {
    final cells = <Widget>[];
    var current = startMonth;

    while (!current.isAfter(endMonth)) {
      final monthStart = DateTime(current.year, current.month, 1);
      final monthEnd = DateTime(current.year, current.month + 1, 0);

      var firstDay = monthStart;
      while (firstDay.weekday != weekday && firstDay.isBefore(monthEnd)) {
        firstDay = firstDay.add(const Duration(days: 1));
      }

      if (firstDay.weekday == weekday && firstDay.isBefore(monthEnd.add(const Duration(days: 1)))) {
        final isCompleted = completionDates.contains(firstDay);
        cells.add(Expanded(
          child: Container(
            height: 20,
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              color: isCompleted ? colorScheme.primary : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ));
      } else {
        cells.add(const Expanded(child: SizedBox(height: 20)));
      }

      current = DateTime(current.year, current.month + 1, 1);
    }

    return cells;
  }

  Widget _buildStreakSection(ColorScheme colorScheme) {
    final streaks = provider.getTargetStreaks(target);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最佳连续完成次数', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colorScheme.primary)),
            const SizedBox(height: 12),
            if (streaks.isEmpty)
              Text('暂无连续记录', style: TextStyle(color: colorScheme.onSurfaceVariant))
            else
              ...streaks.take(5).map((streak) {
                final maxDays = streaks.first.days;
                final progress = maxDays > 0 ? streak.days / maxDays : 0.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          DateFormat('yyyy年M月d日').format(streak.startDate),
                          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Stack(
                          children: [
                            Container(
                              height: 24,
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: progress,
                              child: Container(
                                height: 24,
                                decoration: BoxDecoration(
                                  color: streak.days >= 7 ? colorScheme.primary : colorScheme.secondary,
                                  borderRadius: BorderRadius.circular(4),
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
                                    color: progress > 0.3 ? Colors.white : colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          DateFormat('yyyy年M月d日').format(streak.endDate),
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
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

  Widget _buildFrequencyChart(ColorScheme colorScheme) {
    final weekdayStats = provider.getTargetWeekdayStats(target);
    final maxCount = weekdayStats.values.fold(0, (max, count) => count > max ? count : max);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('频率', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colorScheme.primary)),
            const SizedBox(height: 12),
            ...weekdayStats.entries.map((entry) {
              final progress = maxCount > 0 ? entry.value / maxCount : 0.0;
              final dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text(dayNames[entry.key], style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: Row(
                        children: List.generate(12, (index) {
                          final monthProgress = index < 12 ? progress * (1 - index * 0.08) : 0.0;
                          final size = 8.0 + (monthProgress * 16);
                          return Expanded(
                            child: Center(
                              child: Container(
                                width: size,
                                height: size,
                                decoration: BoxDecoration(
                                  color: colorScheme.primary.withValues(alpha: 0.3 + monthProgress * 0.7),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          );
                        }),
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
}
