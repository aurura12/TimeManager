import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/travel_record.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 桌面月历直接展示记录，宽窗口在右侧保留所选日期与本月记录。
class TravelDesktopCalendar extends StatelessWidget {
  const TravelDesktopCalendar({
    super.key,
    required this.month,
    required this.selectedDate,
    required this.records,
    required this.selectedDateDetails,
    required this.onSelectDate,
    required this.onChangeMonth,
    required this.onPickMonth,
    required this.onToday,
  });

  final DateTime month;
  final DateTime selectedDate;
  final List<TravelRecord> records;
  final Widget selectedDateDetails;
  final ValueChanged<DateTime> onSelectDate;
  final ValueChanged<int> onChangeMonth;
  final VoidCallback onPickMonth;
  final VoidCallback onToday;

  String _dateKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  @override
  Widget build(BuildContext context) {
    final monthRecords = records
        .where((record) =>
            record.date.year == month.year && record.date.month == month.month)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return LayoutBuilder(builder: (context, constraints) {
      final calendar = _buildMonth(context);
      final monthSummary = _buildMonthRecords(context, monthRecords);
      if (constraints.maxWidth >= AppSizes.desktopTravelCalendarBreakpoint) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: calendar),
            const SizedBox(width: AppSpacing.xl),
            SizedBox(
              width: AppSizes.desktopTravelDetailsWidth,
              child: ListView(
                primary: false,
                padding: EdgeInsets.zero,
                children: [
                  selectedDateDetails,
                  const SizedBox(height: AppSpacing.lg),
                  monthSummary,
                ],
              ),
            ),
          ],
        );
      }
      final scale =
          MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) /
              AppText.body.fontSize!;
      return ListView(
        primary: false,
        padding: EdgeInsets.zero,
        children: [
          SizedBox(
            height: AppSizes.desktopTravelCalendarHeight * scale,
            child: calendar,
          ),
          const SizedBox(height: AppSpacing.lg),
          selectedDateDetails,
          const SizedBox(height: AppSpacing.lg),
          monthSummary,
        ],
      );
    });
  }

  Widget _buildMonth(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final firstDay = DateTime(month.year, month.month, 1);
    final firstCell = DateTime(month.year, month.month, 2 - firstDay.weekday);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final weeks = ((firstDay.weekday - 1 + daysInMonth) / 7).ceil();
    final todayKey = _dateKey(DateTime.now());
    final selectedKey = _dateKey(selectedDate);
    final recordsByDate = {
      for (final record in records) record.dateKey: record
    };
    final scale =
        MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) /
            AppText.body.fontSize!;

    return Container(
      key: const ValueKey('travel-desktop-month'),
      padding: AppSpacing.cardComfortable,
      decoration: BoxDecoration(
        color: surfaces.card,
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: surfaces.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: onPickMonth,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${month.year}年${month.month}月',
                            style: AppText.pageTitle),
                        const SizedBox(width: AppSpacing.xs),
                        const Icon(Icons.unfold_more, size: AppSpacing.lg),
                      ],
                    ),
                  ),
                ),
              ),
              TextButton(onPressed: onToday, child: const Text('今天')),
              IconButton(
                tooltip: '上个月',
                onPressed: () => onChangeMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: '下个月',
                onPressed: () => onChangeMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              for (final weekday in const [
                '周一',
                '周二',
                '周三',
                '周四',
                '周五',
                '周六',
                '周日'
              ])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(weekday,
                        textAlign: TextAlign.center,
                        style: AppText.caption
                            .copyWith(color: scheme.onSurfaceVariant)),
                  ),
                ),
            ],
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              final cellHeight =
                  ((constraints.maxHeight - AppSpacing.xs * (weeks - 1)) /
                          weeks)
                      .clamp(AppSizes.desktopTravelCalendarCellHeight * scale,
                          double.infinity);
              return GridView.builder(
                primary: false,
                padding: EdgeInsets.zero,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisExtent: cellHeight,
                  mainAxisSpacing: AppSpacing.xs,
                  crossAxisSpacing: AppSpacing.xs,
                ),
                itemCount: weeks * 7,
                itemBuilder: (context, index) {
                  final date = DateTime(
                      firstCell.year, firstCell.month, firstCell.day + index);
                  final key = _dateKey(date);
                  return _buildDay(
                    context,
                    date: date,
                    record: recordsByDate[key],
                    selected: key == selectedKey,
                    today: key == todayKey,
                  );
                },
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildDay(
    BuildContext context, {
    required DateTime date,
    required TravelRecord? record,
    required bool selected,
    required bool today,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final inMonth = date.month == month.month && date.year == month.year;
    final foreground = selected
        ? scheme.onPrimaryContainer
        : inMonth
            ? scheme.onSurface
            : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      label: DateFormat('yyyy年M月d日').format(date),
      child: Material(
        key: ValueKey('travel-calendar-day-${_dateKey(date)}'),
        color: selected
            ? context.wallpaperFill(scheme.primaryContainer)
            : record != null && inMonth
                ? context.wallpaperFill(scheme.surfaceContainerHigh)
                : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.controlAll,
          side: BorderSide(color: today ? scheme.primary : surfaces.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onSelectDate(date),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('${date.day}',
                          style:
                              AppText.sectionTitle.copyWith(color: foreground)),
                    ),
                    if (today)
                      Text('今',
                          style: AppText.badge.copyWith(color: foreground)),
                  ],
                ),
                if (record != null && inMonth) ...[
                  const SizedBox(height: AppSpacing.md),
                  Tooltip(
                    message: record.location,
                    child: Text(record.location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.button.copyWith(color: foreground)),
                  ),
                  if (record.event.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Expanded(
                      child: Text(record.event,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color:
                                selected ? foreground : scheme.onSurfaceVariant,
                          )),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMonthRecords(BuildContext context, List<TravelRecord> entries) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final places = {
      for (final record in entries)
        ...record.location
            .split(RegExp(r'\s+'))
            .where((place) => place.isNotEmpty),
    };
    return Container(
      padding: AppSpacing.cardComfortable,
      decoration: BoxDecoration(
        color: surfaces.card,
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: surfaces.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('本月出行', style: AppText.sectionTitle)),
              Text('${entries.length} 天', style: AppText.button),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('${places.length} 个地点',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.md),
          if (entries.isEmpty)
            Text('本月暂无出行记录',
                style: AppText.body.copyWith(color: scheme.onSurfaceVariant)),
          for (final record in entries)
            Material(
              key: ValueKey('travel-month-record-${record.dateKey}'),
              color: record.dateKey == _dateKey(selectedDate)
                  ? context.wallpaperFill(scheme.primaryContainer)
                  : Colors.transparent,
              borderRadius: AppRadius.controlAll,
              child: InkWell(
                borderRadius: AppRadius.controlAll,
                onTap: () => onSelectDate(record.date),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: AppSpacing.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(DateFormat('MM/dd').format(record.date),
                          style: AppText.caption),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(record.location,
                                style: AppText.button,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            if (record.event.isNotEmpty) ...[
                              const SizedBox(height: AppSpacing.xs),
                              Text(record.event,
                                  style: AppText.caption
                                      .copyWith(color: scheme.onSurfaceVariant),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
