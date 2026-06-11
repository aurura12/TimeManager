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
        _buildCalendarHeatmap(context, colorScheme),
        const SizedBox(height: 16),
        _buildStreakSection(colorScheme),
        const SizedBox(height: 16),
        _buildFrequencyChart(colorScheme),
      ],
    );
  }

  bool _isTargetCompletedOnDate(Target target, DateTime date) {
    final dateKey = "${date.year}-${date.month}-${date.day}";
    final daySlots = provider.getSlotsForDate(dateKey);
    if (daySlots == null) return false;
    return daySlots.any((s) => provider.slotMatchesTarget(s, target));
  }

  int _getTargetCountOnDate(Target target, DateTime date) {
    final dateKey = "${date.year}-${date.month}-${date.day}";
    final daySlots = provider.getSlotsForDate(dateKey);
    if (daySlots == null) return 0;
    return daySlots.where((s) => provider.slotMatchesTarget(s, target)).length;
  }

  Widget _buildGoalSection(ColorScheme colorScheme) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    final endOfWeek = startOfWeek.add(const Duration(days: 7));

    final startOfMonth = DateTime(now.year, now.month, 1);
    final endOfMonth = DateTime(now.year, now.month + 1, 1);

    final quarter = (now.month - 1) ~/ 3;
    final startOfQuarter = DateTime(now.year, quarter * 3 + 1, 1);
    final endOfQuarter = DateTime(now.year, quarter * 3 + 4, 1);

    final startOfYear = DateTime(now.year, 1, 1);
    final endOfYear = DateTime(now.year + 1, 1, 1);

    final todayCount = _getTargetCountOnDate(target, today);
    final weekCount = provider.getTargetCompletionCount(target, startOfWeek, endOfWeek);
    final monthCount = provider.getTargetCompletionCount(target, startOfMonth, endOfMonth);
    final quarterCount = provider.getTargetCompletionCount(target, startOfQuarter, endOfQuarter);
    final yearCount = provider.getTargetCompletionCount(target, startOfYear, endOfYear);

    final dailyGoal = _getDailyGoal();
    final weeklyGoal = dailyGoal * 7;
    final monthlyGoal = dailyGoal * 30;
    final quarterlyGoal = dailyGoal * 91;
    final yearlyGoal = dailyGoal * 365;

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

  int _getDailyGoal() {
    if (target.type == TargetType.frequency) {
      return target.frequencyCount;
    }
    return 1;
  }

  Widget _buildProgressRow(String label, int current, int goal, ColorScheme colorScheme) {
    final progress = goal > 0 ? (current / goal).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 45,
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
            width: 45,
            child: Text('$goal', style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant), textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceChart(ColorScheme colorScheme) {
    final now = DateTime.now();
    final monthlyStats = <String, int>{};

    for (int i = 11; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final nextMonth = DateTime(now.year, now.month - i + 1, 1);
      final count = provider.getTargetCompletionCount(target, month, nextMonth);
      final key = "${month.year}-${month.month.toString().padLeft(2, '0')}";
      monthlyStats[key] = count;
    }

    final monthlyGoal = _getDailyGoal() * 30;
    final spots = <FlSpot>[];
    final labels = <String>[];
    var index = 0;

    monthlyStats.forEach((key, value) {
      final percentage = monthlyGoal > 0 ? (value / monthlyGoal * 100).clamp(0.0, 100.0) : 0.0;
      spots.add(FlSpot(index.toDouble(), percentage));
      labels.add(key.substring(5));
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
    final now = DateTime.now();
    final monthlyStats = <String, int>{};

    for (int i = 11; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final nextMonth = DateTime(now.year, now.month - i + 1, 1);
      final count = provider.getTargetCompletionCount(target, month, nextMonth);
      final key = "${month.year}-${month.month.toString().padLeft(2, '0')}";
      monthlyStats[key] = count;
    }

    final bars = <BarChartGroupData>[];
    final labels = <String>[];
    var index = 0;
    var maxValue = 0;

    monthlyStats.forEach((key, value) {
      bars.add(BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: value.toDouble(),
            color: colorScheme.primary,
            width: 20,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
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

  Widget _buildCalendarHeatmap(BuildContext context, ColorScheme colorScheme) {
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
            _buildRealCalendar(startMonth, now, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildRealCalendar(DateTime startMonth, DateTime now, ColorScheme colorScheme) {
    final today = DateTime(now.year, now.month, now.day);
    final weeks = ['一', '二', '三', '四', '五', '六', '日'];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              const SizedBox(height: 22),
              ...weeks.map((w) => Container(
                height: 18,
                width: 20,
                alignment: Alignment.center,
                child: Text(w, style: TextStyle(fontSize: 10, color: colorScheme.onSurfaceVariant)),
              )),
            ],
          ),
          ...List.generate(6, (index) {
            final month = DateTime(startMonth.year, startMonth.month + index, 1);
            return _buildMonthCalendar(month, today, colorScheme);
          }),
        ],
      ),
    );
  }

  Widget _buildMonthCalendar(DateTime month, DateTime today, ColorScheme colorScheme) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstDayWeekday = DateTime(month.year, month.month, 1).weekday;

    return Container(
      width: 160,
      margin: const EdgeInsets.only(right: 8),
      child: Column(
        children: [
          Text(
            '${month.year}年${month.month}月',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          ...List.generate(6, (weekIndex) {
            return Row(
              children: List.generate(7, (dayIndex) {
                final dayOffset = weekIndex * 7 + dayIndex - firstDayWeekday + 1;
                final day = dayOffset;

                if (day < 1 || day > daysInMonth) {
                  return Container(
                    height: 18,
                    width: 18,
                    margin: const EdgeInsets.all(2),
                  );
                }

                final date = DateTime(month.year, month.month, day);
                final isCompleted = _isTargetCompletedOnDate(target, date);
                final isToday = date.isAtSameMomentAs(today);

                return Container(
                  height: 18,
                  width: 18,
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: isCompleted
                        ? colorScheme.primary
                        : isToday
                            ? colorScheme.primary.withValues(alpha: 0.2)
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(3),
                    border: isToday && !isCompleted
                        ? Border.all(color: colorScheme.primary, width: 1)
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$day',
                    style: TextStyle(
                      fontSize: 10,
                      color: isCompleted
                          ? Colors.white
                          : isToday
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                      fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                );
              }),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildStreakSection(ColorScheme colorScheme) {
    final streaks = _calculateStreaks();

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
                      SizedBox(
                        width: 60,
                        child: Text(
                          DateFormat('M/d').format(streak.startDate),
                          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                        ),
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
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 60,
                        child: Text(
                          DateFormat('M/d').format(streak.endDate),
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

  List<_StreakData> _calculateStreaks() {
    final now = DateTime.now();
    final completionDates = <DateTime>{};

    for (int i = 0; i < 365; i++) {
      final date = now.subtract(Duration(days: i));
      if (_isTargetCompletedOnDate(target, date)) {
        completionDates.add(DateTime(date.year, date.month, date.day));
      }
    }

    if (completionDates.isEmpty) return [];

    final sortedDates = completionDates.toList()..sort((a, b) => a.compareTo(b));
    final streaks = <_StreakData>[];

    var streakStart = sortedDates[0];
    var streakEnd = sortedDates[0];
    var streakDays = 1;

    for (int i = 1; i < sortedDates.length; i++) {
      final diff = sortedDates[i].difference(streakEnd).inDays;
      if (diff == 1) {
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

  Widget _buildFrequencyChart(ColorScheme colorScheme) {
    final now = DateTime.now();
    final weekdayStats = <int, int>{1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0};

    for (int i = 0; i < 365; i++) {
      final date = now.subtract(Duration(days: i));
      if (_isTargetCompletedOnDate(target, date)) {
        final weekday = date.weekday;
        weekdayStats[weekday] = (weekdayStats[weekday] ?? 0) + 1;
      }
    }

    final dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    final monthLabels = <String>[];
    for (int i = 11; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      monthLabels.add('${month.month}月');
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('频率', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colorScheme.primary)),
            const SizedBox(height: 12),
            // 可水平滚动的频率图
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 月份标签行
                  Row(
                    children: [
                      const SizedBox(width: 40),
                      ...monthLabels.map((label) => SizedBox(
                        width: 30,
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 9, color: colorScheme.onSurfaceVariant),
                        ),
                      )),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 频率数据行
                  ...weekdayStats.entries.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text(dayNames[entry.key], style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                          ),
                          ...List.generate(12, (monthIndex) {
                            final month = DateTime(now.year, now.month - (11 - monthIndex), 1);
                            final monthEnd = DateTime(now.year, now.month - (11 - monthIndex) + 1, 0);
                            var monthWeekdayCount = 0;

                            for (var d = month; !d.isAfter(monthEnd); d = d.add(const Duration(days: 1))) {
                              if (d.weekday == entry.key && _isTargetCompletedOnDate(target, d)) {
                                monthWeekdayCount++;
                              }
                            }

                            final monthProgress = monthWeekdayCount > 0 ? (monthWeekdayCount / 5).clamp(0.0, 1.0) : 0.0;
                            final size = 6.0 + (monthProgress * 14);

                            return SizedBox(
                              width: 30,
                              child: Center(
                                child: monthProgress > 0
                                    ? Container(
                                        width: size,
                                        height: size,
                                        decoration: BoxDecoration(
                                          color: colorScheme.primary.withValues(alpha: 0.3 + monthProgress * 0.7),
                                          shape: BoxShape.circle,
                                        ),
                                      )
                                    : const SizedBox(width: 6, height: 6),
                              ),
                            );
                          }),
                        ],
                      ),
                    );
                  }),
                ],
              ),
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
