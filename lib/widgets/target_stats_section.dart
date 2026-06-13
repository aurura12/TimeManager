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

  // --- 通用方法 ---

  String _dateKey(DateTime date) => "${date.year}-${date.month}-${date.day}";

  bool _isTargetCompletedOnDate(Target target, DateTime date) {
    if (target.type == TargetType.timePoint) {
      final dateKey = _dateKey(date);
      // 检查缓存
      final cached = provider.targetStatsCache.getCachedTimePointStatus(target.id, dateKey);
      if (cached != null) {
        return cached == TimePointStatus.onTime || cached == TimePointStatus.late;
      }
      final status = provider.getTimePointStatus(target, date);
      provider.targetStatsCache.cacheTimePointStatus(target.id, dateKey, status);
      return status == TimePointStatus.onTime || status == TimePointStatus.late;
    }
    final daySlots = provider.getSlotsForDate(_dateKey(date));
    if (daySlots == null) return false;
    return daySlots.any((s) => provider.slotMatchesTarget(s, target));
  }

  /// 计算目标在某天的完成次数（频率目标按连续块计数，时长目标按小时计数）
  double _getTargetCountOnDate(Target target, DateTime date) {
    final dateKey = _dateKey(date);

    // 检查缓存
    final cached = provider.targetStatsCache.getCachedCount(target.id, dateKey);
    if (cached != null) return cached;

    final daySlots = provider.getSlotsForDate(dateKey);
    if (daySlots == null) {
      provider.targetStatsCache.cacheCount(target.id, dateKey, 0);
      return 0;
    }

    double result;
    if (target.type == TargetType.frequency) {
      int blocks = 0;
      bool inBlock = false;
      for (var slot in daySlots) {
        if (provider.slotMatchesTarget(slot, target)) {
          if (!inBlock) {
            blocks++;
            inBlock = true;
          }
        } else {
          inBlock = false;
        }
      }
      result = blocks.toDouble();
    } else {
      int count = daySlots.where((s) => provider.slotMatchesTarget(s, target)).length;
      result = count * 10.0 / 60.0;
    }

    provider.targetStatsCache.cacheCount(target.id, dateKey, result);
    return result;
  }

  /// 计算目标在日期范围内的总完成次数
  double _getTargetCompletionCountInRange(Target target, DateTime start, DateTime end) {
    double total = 0;
    for (var d = start; d.isBefore(end); d = d.add(const Duration(days: 1))) {
      total += _getTargetCountOnDate(target, d);
    }
    return total;
  }

  // --- 时间点目标专用方法 ---

  /// 获取时间点目标在日期范围内的准时率（0.0~1.0）
  double _getTimePointOnTimeRate(Target target, DateTime start, DateTime end) {
    int onTime = 0;
    int total = 0;
    for (var d = start; d.isBefore(end); d = d.add(const Duration(days: 1))) {
      final dateKey = _dateKey(d);
      final cached = provider.targetStatsCache.getCachedTimePointStatus(target.id, dateKey);
      TimePointStatus status;
      if (cached != null) {
        status = cached;
      } else {
        status = provider.getTimePointStatus(target, d);
        provider.targetStatsCache.cacheTimePointStatus(target.id, dateKey, status);
      }
      if (status == TimePointStatus.onTime || status == TimePointStatus.late) {
        total++;
        if (status == TimePointStatus.onTime) onTime++;
      }
    }
    return total > 0 ? onTime / total : 0.0;
  }

  // --- 目标值计算 ---

  /// 根据周期正确计算每日目标值
  double _getDailyGoal() {
    if (target.type == TargetType.frequency) {
      final count = target.frequencyCount.toDouble();
      if (target.period == "每天" || target.period == "今天") {
        return count;
      } else if (target.period == "每周" || target.period == "本周" || target.period == "一周内") {
        return count / 7.0;
      } else if (target.period == "每月" || target.period == "本月" || target.period == "一月内") {
        return count / 30.0;
      } else if (target.period == "每年" || target.period == "今年" || target.period == "一年内") {
        return count / 365.0;
      } else if (target.period.startsWith("每") && target.period.endsWith("天")) {
        final match = RegExp(r'每(\d+)天').firstMatch(target.period);
        if (match != null) {
          final days = int.tryParse(match.group(1) ?? '');
          if (days != null && days > 0) {
            return count / days;
          }
        }
      }
      return count;
    }
    return 1;
  }

  // --- 目标进度条 ---

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

    final dailyGoal = _getDailyGoal();
    final weeklyGoal = dailyGoal * 7;
    final monthlyGoal = dailyGoal * 30;
    final quarterlyGoal = dailyGoal * 91;
    final yearlyGoal = dailyGoal * 365;

    if (target.type == TargetType.timePoint) {
      final todayStatus = provider.getTimePointStatus(target, today);
      final weekRate = _getTimePointOnTimeRate(target, startOfWeek, endOfWeek);
      final monthRate = _getTimePointOnTimeRate(target, startOfMonth, endOfMonth);
      final quarterRate = _getTimePointOnTimeRate(target, startOfQuarter, endOfQuarter);
      final yearRate = _getTimePointOnTimeRate(target, startOfYear, endOfYear);

      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('目标', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colorScheme.primary)),
              const SizedBox(height: 12),
              _buildTimePointTodayRow(todayStatus, colorScheme),
              _buildProgressRow('周', weekRate, 1.0, colorScheme, isRate: true),
              _buildProgressRow('月', monthRate, 1.0, colorScheme, isRate: true),
              _buildProgressRow('季度', quarterRate, 1.0, colorScheme, isRate: true),
              _buildProgressRow('年', yearRate, 1.0, colorScheme, isRate: true),
            ],
          ),
        ),
      );
    }

    final todayCount = _getTargetCountOnDate(target, today);
    final weekCount = _getTargetCompletionCountInRange(target, startOfWeek, endOfWeek);
    final monthCount = _getTargetCompletionCountInRange(target, startOfMonth, endOfMonth);
    final quarterCount = _getTargetCompletionCountInRange(target, startOfQuarter, endOfQuarter);
    final yearCount = _getTargetCompletionCountInRange(target, startOfYear, endOfYear);

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

  Widget _buildTimePointTodayRow(TimePointStatus status, ColorScheme colorScheme) {
    String text;
    Color color;
    switch (status) {
      case TimePointStatus.onTime:
        text = '准时';
        color = Colors.green;
        break;
      case TimePointStatus.late:
        text = '迟到';
        color = Colors.orange;
        break;
      case TimePointStatus.notDone:
        text = '未做';
        color = colorScheme.onSurfaceVariant;
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 45,
            child: Text('今日', style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Container(
              height: 24,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressRow(String label, double current, double goal, ColorScheme colorScheme, {bool isRate = false}) {
    final progress = goal > 0 ? (current / goal).clamp(0.0, 1.0) : 0.0;
    String displayText;
    if (isRate) {
      displayText = '${(current * 100).toStringAsFixed(0)}%';
    } else if (target.type == TargetType.duration) {
      displayText = '${current.toStringAsFixed(1)}h';
    } else {
      displayText = current < 1 ? current.toStringAsFixed(1) : '${current.toInt()}';
    }

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
                      displayText,
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
        ],
      ),
    );
  }

  // --- 成绩折线图 ---

  Widget _buildPerformanceChart(ColorScheme colorScheme) {
    final now = DateTime.now();
    final monthlyStats = <String, double>{};

    for (int i = 11; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final nextMonth = DateTime(now.year, now.month - i + 1, 1);
      final key = "${month.year}-${month.month.toString().padLeft(2, '0')}";

      if (target.type == TargetType.timePoint) {
        monthlyStats[key] = _getTimePointOnTimeRate(target, month, nextMonth) * 100;
      } else {
        final count = _getTargetCompletionCountInRange(target, month, nextMonth);
        final monthlyGoal = _getDailyGoal() * 30;
        monthlyStats[key] = monthlyGoal > 0 ? (count / monthlyGoal * 100).clamp(0.0, 100.0) : 0.0;
      }
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
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          return LineTooltipItem(
                            '${spot.y.toStringAsFixed(2)}%',
                            TextStyle(
                              color: Colors.white,
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

  // --- 历史柱状图 ---

  Widget _buildHistoryChart(ColorScheme colorScheme) {
    final now = DateTime.now();
    final monthlyStats = <String, double>{};

    for (int i = 11; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final nextMonth = DateTime(now.year, now.month - i + 1, 1);
      final key = "${month.year}-${month.month.toString().padLeft(2, '0')}";

      if (target.type == TargetType.timePoint) {
        monthlyStats[key] = _getTimePointOnTimeRate(target, month, nextMonth) * 100;
      } else {
        monthlyStats[key] = _getTargetCompletionCountInRange(target, month, nextMonth);
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
                        final displayValue = target.type == TargetType.timePoint
                            ? '${rod.toY.toStringAsFixed(1)}%'
                            : target.type == TargetType.duration
                                ? '${rod.toY.toStringAsFixed(1)}h'
                                : '${rod.toY.toInt()}';
                        return BarTooltipItem(
                          displayValue,
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

  // --- 日历热力图 ---

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

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
    final weeks = ['一', '二', '三', '四', '五', '六', '日'];

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
          Row(
            children: weeks.map((w) => SizedBox(
              width: 22,
              child: Text(
                w,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9, color: colorScheme.onSurfaceVariant),
              ),
            )).toList(),
          ),
          const SizedBox(height: 2),
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
                final isToday = date.isAtSameMomentAs(today);

                if (target.type == TargetType.timePoint) {
                  final status = provider.getTimePointStatus(target, date);
                  return _buildTimePointCalendarCell(day, status, isToday, colorScheme);
                } else {
                  final isCompleted = _isTargetCompletedOnDate(target, date);
                  return _buildNormalCalendarCell(day, isCompleted, isToday, colorScheme);
                }
              }),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTimePointCalendarCell(int day, TimePointStatus status, bool isToday, ColorScheme colorScheme) {
    Color bgColor;
    Color textColor;

    switch (status) {
      case TimePointStatus.onTime:
        bgColor = Colors.green;
        textColor = Colors.white;
        break;
      case TimePointStatus.late:
        bgColor = Colors.orange;
        textColor = Colors.white;
        break;
      case TimePointStatus.notDone:
        bgColor = isToday ? colorScheme.primary.withValues(alpha: 0.2) : Colors.transparent;
        textColor = isToday ? colorScheme.primary : colorScheme.onSurfaceVariant;
        break;
    }

    return Container(
      height: 18,
      width: 18,
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(3),
        border: isToday && status == TimePointStatus.notDone
            ? Border.all(color: colorScheme.primary, width: 1)
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        '$day',
        style: TextStyle(
          fontSize: 10,
          color: textColor,
          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _buildNormalCalendarCell(int day, bool isCompleted, bool isToday, ColorScheme colorScheme) {
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
          color: isCompleted ? Colors.white : colorScheme.onSurfaceVariant,
          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
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

      if (target.type == TargetType.timePoint) {
        // 时间点目标：只统计准时（绿色）
        if (provider.getTimePointStatus(target, date) == TimePointStatus.onTime) {
          completionDates.add(DateTime(date.year, date.month, date.day));
        }
      } else {
        if (_isTargetCompletedOnDate(target, date)) {
          completionDates.add(DateTime(date.year, date.month, date.day));
        }
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

  // --- 频率气泡图 ---

  Widget _buildFrequencyChart(ColorScheme colorScheme) {
    final now = DateTime.now();
    final weekdayStats = <int, int>{1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0};

    for (int i = 0; i < 365; i++) {
      final date = now.subtract(Duration(days: i));

      if (target.type == TargetType.timePoint) {
        // 时间点目标：统计周几准时次数
        if (provider.getTimePointStatus(target, date) == TimePointStatus.onTime) {
          weekdayStats[date.weekday] = (weekdayStats[date.weekday] ?? 0) + 1;
        }
      } else {
        if (_isTargetCompletedOnDate(target, date)) {
          weekdayStats[date.weekday] = (weekdayStats[date.weekday] ?? 0) + 1;
        }
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
            Row(
              children: [
                Column(
                  children: [
                    const SizedBox(height: 18),
                    ...List.generate(7, (i) => Container(
                      height: 24,
                      width: 36,
                      alignment: Alignment.centerRight,
                      child: Text(dayNames[i + 1], style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                    )),
                  ],
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: monthLabels.map((label) => SizedBox(
                            width: 30,
                            child: Text(
                              label,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 9, color: colorScheme.onSurfaceVariant),
                            ),
                          )).toList(),
                        ),
                        const SizedBox(height: 4),
                        ...weekdayStats.entries.map((entry) {
                          return Row(
                            children: List.generate(12, (monthIndex) {
                              final month = DateTime(now.year, now.month - (11 - monthIndex), 1);
                              final monthEnd = DateTime(now.year, now.month - (11 - monthIndex) + 1, 0);
                              var monthWeekdayCount = 0;

                              for (var d = month; !d.isAfter(monthEnd); d = d.add(const Duration(days: 1))) {
                                if (d.weekday == entry.key) {
                                  if (target.type == TargetType.timePoint) {
                                    if (provider.getTimePointStatus(target, d) == TimePointStatus.onTime) {
                                      monthWeekdayCount++;
                                    }
                                  } else {
                                    if (_isTargetCompletedOnDate(target, d)) {
                                      monthWeekdayCount++;
                                    }
                                  }
                                }
                              }

                              final monthProgress = monthWeekdayCount > 0 ? (monthWeekdayCount / 5).clamp(0.0, 1.0) : 0.0;
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
                                            color: colorScheme.primary.withValues(alpha: 0.3 + monthProgress * 0.7),
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
