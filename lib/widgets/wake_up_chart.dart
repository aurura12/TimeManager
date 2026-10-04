import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/wake_up_record.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 按自然日绘制起床时刻；空缺日期断开曲线，不按零点补值。
class WakeUpChart extends StatelessWidget {
  const WakeUpChart({
    super.key,
    required DateTime today,
    required this.records,
  })  : endDate = today,
        startDate = null,
        periodLabel = '最近 7 天',
        _showTodayLabel = true;

  const WakeUpChart.range({
    super.key,
    required this.startDate,
    required this.endDate,
    required this.records,
    required this.periodLabel,
  }) : _showTodayLabel = false;

  final DateTime? startDate;
  final DateTime endDate;
  final List<WakeUpRecord> records;
  final String periodLabel;
  final bool _showTodayLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = AppText.caption.copyWith(color: scheme.onSurfaceVariant);
    final textScale =
        MediaQuery.textScalerOf(context).scale(AppText.caption.fontSize!) /
            AppText.caption.fontSize!;
    final start =
        startDate ?? DateTime(endDate.year, endDate.month, endDate.day - 6);
    // 用 UTC 的日期组件求天数，避免夏令时让自然日变成 23 / 25 小时。
    final dayCount = DateTime.utc(endDate.year, endDate.month, endDate.day)
            .difference(DateTime.utc(start.year, start.month, start.day))
            .inDays +
        1;
    final dates = [
      for (var index = 0; index < dayCount; index++)
        DateTime(start.year, start.month, start.day + index),
    ];
    final byDate = {for (final record in records) record.dateKey: record};
    final daily = [
      for (final date in dates) byDate[WakeUpRecord.keyForDate(date)],
    ];
    final minutes = [
      for (final record in daily)
        if (record != null) record.minuteOfDay,
    ];
    final minY = minutes.isEmpty
        ? 360.0
        : math.max(0, (minutes.reduce(math.min) ~/ 60 - 1) * 60).toDouble();
    final maxY = minutes.isEmpty
        ? 600.0
        : math
            .min(1440, ((minutes.reduce(math.max) / 60).ceil() + 1) * 60)
            .toDouble();
    final interval = [30.0, 60.0, 120.0, 180.0, 240.0, 360.0]
        .firstWhere((step) => step >= (maxY - minY) / 4);
    final leftSize = AppSizes.button * textScale + AppSpacing.sm;
    final bottomSize = AppSpacing.xl * textScale;

    return Semantics(
      key: const ValueKey('wake-up-chart'),
      label: '$periodLabel起床时间曲线图',
      value: [
        for (var index = 0; index < dates.length; index++)
          if (_showTodayLabel || daily[index] != null)
            '${_showTodayLabel ? '' : '${dates[index].year}年'}'
                '${dates[index].month}月${dates[index].day}日 '
                '${daily[index]?.timeLabel ?? '未记录'}',
      ].join('，'),
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$periodLabel起床趋势', style: labelStyle),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              height: AppSizes.listRow * 3 + AppSpacing.xl * (textScale - 1),
              child: LayoutBuilder(builder: (context, constraints) {
                final plotWidth =
                    constraints.maxWidth - leftSize - AppSpacing.md;
                final crossesYear = start.year != endDate.year;
                final labelWidth =
                    AppSizes.minTapTarget * textScale * (crossesYear ? 1.5 : 1);
                final labelCount =
                    math.max(2, (plotWidth / labelWidth).floor());
                final dateInterval =
                    math.max(1.0, (dates.length - 1) / (labelCount - 1));
                return Padding(
                  padding: const EdgeInsets.only(
                      top: AppSpacing.sm, right: AppSpacing.md),
                  child: Stack(
                    children: [
                      LineChart(
                        // 换日期、删记录和切身份时直接绘制真实值，避免补间出虚构时刻。
                        duration: Duration.zero,
                        LineChartData(
                          minX: 0,
                          maxX: math.max(1, dates.length - 1).toDouble(),
                          minY: minY,
                          maxY: maxY,
                          borderData: FlBorderData(show: false),
                          gridData: FlGridData(
                            drawVerticalLine: false,
                            horizontalInterval: interval,
                            getDrawingHorizontalLine: (_) => FlLine(
                              color: scheme.outlineVariant,
                              strokeWidth: AppSizes.hairline,
                              dashArray: [
                                AppSpacing.xs.toInt(),
                                AppSpacing.xs.toInt()
                              ],
                            ),
                          ),
                          titlesData: FlTitlesData(
                            topTitles: const AxisTitles(),
                            rightTitles: const AxisTitles(),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: leftSize,
                                interval: interval,
                                minIncluded: false,
                                maxIncluded: false,
                                getTitlesWidget: (value, meta) =>
                                    SideTitleWidget(
                                  meta: meta,
                                  space: AppSpacing.sm,
                                  child: Text(
                                    WakeUpRecord.labelForMinute(value.round()),
                                    style: labelStyle,
                                  ),
                                ),
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: bottomSize,
                                interval: dateInterval,
                                maxIncluded: dates.length > 1,
                                getTitlesWidget: (value, meta) {
                                  final index = value.round();
                                  if (index < 0 || index >= dates.length) {
                                    return const SizedBox.shrink();
                                  }
                                  final date = dates[index];
                                  final isToday = _showTodayLabel &&
                                      index == dates.length - 1;
                                  return SideTitleWidget(
                                    meta: meta,
                                    space: AppSpacing.sm,
                                    fitInside:
                                        SideTitleFitInsideData.fromTitleMeta(
                                            meta),
                                    child: Text(
                                      isToday
                                          ? '今天'
                                          : '${crossesYear ? '${date.year % 100}/' : ''}'
                                              '${date.month}/${date.day}',
                                      style: labelStyle.copyWith(
                                        color: isToday
                                            ? scheme.primary
                                            : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          lineBarsData: [
                            if (minutes.isNotEmpty)
                              LineChartBarData(
                                spots: [
                                  for (var index = 0;
                                      index < daily.length;
                                      index++)
                                    daily[index] == null
                                        ? FlSpot.nullSpot
                                        : FlSpot(
                                            index.toDouble(),
                                            daily[index]!
                                                .minuteOfDay
                                                .toDouble()),
                                ],
                                color: scheme.primary,
                                barWidth: AppSizes.border * 2,
                                isCurved: true,
                                preventCurveOverShooting: true,
                                isStrokeCapRound: true,
                                dotData: FlDotData(
                                  getDotPainter: (spot, percent, bar, index) =>
                                      FlDotCirclePainter(
                                    radius: dates.length > 90
                                        ? AppSizes.border * 2
                                        : AppSpacing.xs,
                                    color: scheme.primary,
                                    strokeWidth: AppSizes.border * 2,
                                    strokeColor: AppSurfaces.of(context).card,
                                  ),
                                ),
                              ),
                          ],
                          lineTouchData: LineTouchData(
                            enabled: minutes.isNotEmpty,
                            touchTooltipData: LineTouchTooltipData(
                              tooltipBorderRadius: AppRadius.badgeAll,
                              tooltipPadding:
                                  const EdgeInsets.all(AppSpacing.sm),
                              fitInsideHorizontally: true,
                              fitInsideVertically: true,
                              getTooltipColor: (_) => scheme.inverseSurface,
                              getTooltipItems: (spots) => [
                                for (final spot in spots)
                                  LineTooltipItem(
                                    '${_showTodayLabel ? '' : '${dates[spot.x.toInt()].year}年'}'
                                    '${dates[spot.x.toInt()].month}月'
                                    '${dates[spot.x.toInt()].day}日\n'
                                    '${WakeUpRecord.labelForMinute(spot.y.round())}',
                                    AppText.caption.copyWith(
                                        color: scheme.onInverseSurface),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (minutes.isEmpty)
                        Positioned.fill(
                          left: leftSize,
                          bottom: bottomSize,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              decoration: BoxDecoration(
                                color: context.wallpaperFill(
                                    AppSurfaces.of(context).card),
                                borderRadius: AppRadius.badgeAll,
                              ),
                              child: Text('记录后即可查看起床趋势',
                                  textAlign: TextAlign.center,
                                  style: labelStyle),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
