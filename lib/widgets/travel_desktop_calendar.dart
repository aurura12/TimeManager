import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/travel_record.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 桌面出行月历按窗口宽度并排多个月份（最多 6 个月，宽屏为 3 列两行），
/// 并保留单月详细视图。格子沿用移动端的干净样式。
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
    this.multiMonth = false,
    this.onToggleMultiMonth,
  });

  /// 多月视图一次展示的月份数量（宽屏 3 列两行）。
  static const int multiMonthCount = 6;

  final DateTime month;
  final DateTime selectedDate;
  final List<TravelRecord> records;
  final Widget selectedDateDetails;
  final ValueChanged<DateTime> onSelectDate;
  final ValueChanged<int> onChangeMonth;
  final VoidCallback onPickMonth;
  final VoidCallback onToday;
  final bool multiMonth;
  final ValueChanged<bool>? onToggleMultiMonth;

  String _dateKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);
  String _monthLabel(DateTime value) => '${value.year}年${value.month}月';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final selectedMonth = DateTime(selectedDate.year, selectedDate.month);
      final monthRecords = _recordsInMonth(selectedMonth);
      final monthSummary = _buildMonthRecords(context, monthRecords);
      if (constraints.maxWidth >= AppSizes.desktopTravelDetailsBreakpoint) {
        final calendar = multiMonth
            ? _buildMultiMonthCalendar(
                context,
                availableWidth: constraints.maxWidth,
              )
            : _buildMonth(context);
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

      if (multiMonth) {
        return Column(
          children: [
            _buildSelectedDateSummary(
              context,
              showAsDialog: constraints.maxWidth >=
                  AppSizes.desktopTravelThreeMonthBreakpoint,
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: _buildMultiMonthCalendar(
                context,
                availableWidth: constraints.maxWidth,
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
            child: _buildMonth(context),
          ),
          const SizedBox(height: AppSpacing.lg),
          selectedDateDetails,
          const SizedBox(height: AppSpacing.lg),
          monthSummary,
        ],
      );
    });
  }

  List<TravelRecord> _recordsInMonth(DateTime value) => records
      .where((record) =>
          record.date.year == value.year && record.date.month == value.month)
      .toList()
    ..sort((a, b) => b.date.compareTo(a.date));

  Widget _buildMonthModeSwitch() => SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment<bool>(value: false, label: Text('单月')),
          ButtonSegment<bool>(value: true, label: Text('多月')),
        ],
        selected: {multiMonth},
        onSelectionChanged: onToggleMultiMonth == null
            ? null
            : (selection) => onToggleMultiMonth!(selection.first),
      );

  String _rangeLabel() {
    if (!multiMonth) return _monthLabel(month);
    final end = DateTime(month.year, month.month + multiMonthCount - 1);
    final endLabel =
        end.year == month.year ? '${end.month}月' : _monthLabel(end);
    return '${_monthLabel(month)} — $endLabel';
  }

  Widget _buildCalendarToolbar(BuildContext context) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          TextButton(
            onPressed: onPickMonth,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_rangeLabel(), style: AppText.pageTitle),
                const SizedBox(width: AppSpacing.xs),
                const Icon(Icons.unfold_more, size: AppSpacing.lg),
              ],
            ),
          ),
          _buildMonthModeSwitch(),
          TextButton(onPressed: onToday, child: const Text('今天')),
          IconButton(
            tooltip: multiMonth ? '上一个月' : '上个月',
            onPressed: () => onChangeMonth(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: multiMonth ? '下一个月' : '下个月',
            onPressed: () => onChangeMonth(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      );

  Widget _buildMultiMonthCalendar(
    BuildContext context, {
    required double availableWidth,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final scale =
        MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) /
            AppText.body.fontSize!;
    final recordsByDate = {
      for (final record in records) record.dateKey: record,
    };
    final columns = availableWidth >= AppSizes.desktopTravelThreeMonthBreakpoint
        ? 3
        : availableWidth >= AppSizes.desktopTravelTwoMonthBreakpoint
            ? 2
            : 1;
    final rows = (multiMonthCount / columns).ceil();
    return Container(
      key: const ValueKey('travel-desktop-multi-month'),
      padding: AppSpacing.cardComfortable,
      decoration: BoxDecoration(
        color: surfaces.card,
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: surfaces.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCalendarToolbar(context),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              // 一屏放下全部月份；窗口太矮时收紧到最小高度并允许滚动。
              final rowHeight =
                  ((constraints.maxHeight - AppSpacing.md * (rows - 1)) / rows)
                      .clamp(
                          AppSizes.desktopTravelMultiMonthCardMinHeight * scale,
                          double.infinity);
              return GridView.builder(
                primary: false,
                padding: EdgeInsets.zero,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: rowHeight,
                  mainAxisSpacing: AppSpacing.md,
                  crossAxisSpacing: AppSpacing.md,
                ),
                itemCount: multiMonthCount,
                itemBuilder: (context, index) => _buildCompactMonth(
                  context,
                  DateTime(month.year, month.month + index),
                  recordsByDate: recordsByDate,
                  scheme: scheme,
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMonth(
    BuildContext context,
    DateTime date, {
    required Map<String, TravelRecord> recordsByDate,
    required ColorScheme scheme,
  }) {
    final daysInMonth = DateTime(date.year, date.month + 1, 0).day;
    final startOffset = (DateTime(date.year, date.month, 1).weekday - 1) % 7;
    final weeks = ((startOffset + daysInMonth) / 7).ceil();
    final todayKey = _dateKey(DateTime.now());
    final selectedKey = _dateKey(selectedDate);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text(
              _monthLabel(date),
              textAlign: TextAlign.center,
              style: AppText.sectionTitle,
            ),
          ),
          Row(
            children: [
              for (final weekday in const ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(
                      weekday,
                      textAlign: TextAlign.center,
                      style: AppText.caption.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Expanded(
            child: Column(
              children: List.generate(weeks, (week) {
                return Expanded(
                  child: Row(
                    children: List.generate(7, (weekday) {
                      final day = week * 7 + weekday - startOffset + 1;
                      if (day < 1 || day > daysInMonth) {
                        return const Expanded(child: SizedBox.shrink());
                      }
                      final dayDate = DateTime(date.year, date.month, day);
                      final key = _dateKey(dayDate);
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.xs / 2),
                          child: _buildCompactDay(
                            context,
                            date: dayDate,
                            record: recordsByDate[key],
                            selected: key == selectedKey,
                            today: key == todayKey,
                            scheme: scheme,
                          ),
                        ),
                      );
                    }),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactDay(
    BuildContext context, {
    required DateTime date,
    required TravelRecord? record,
    required bool selected,
    required bool today,
    required ColorScheme scheme,
  }) {
    final foreground = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    return Semantics(
      selected: selected,
      button: true,
      label: '${DateFormat('yyyy年M月d日').format(date)}'
          '${record == null ? '' : '，${record.location}'}',
      child: Material(
        key: ValueKey('travel-calendar-day-${_dateKey(date)}'),
        color: selected
            ? context.wallpaperFill(scheme.primaryContainer)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.badgeAll,
          side: today
              ? BorderSide(color: scheme.primary, width: 1.5)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onSelectDate(date),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                '${date.day}',
                style: AppText.body.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              if (record != null)
                const Positioned(
                  bottom: 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppSemanticColors.success,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(width: 5, height: 5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedDateSummary(
    BuildContext context, {
    required bool showAsDialog,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final record = records
        .where((item) => item.dateKey == _dateKey(selectedDate))
        .firstOrNull;
    final weekdays = const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return Card(
      margin: EdgeInsets.zero,
      child: LayoutBuilder(builder: (context, constraints) {
        final compact =
            constraints.maxWidth < AppSizes.desktopTravelTwoMonthBreakpoint;
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.event_note_outlined, color: scheme.primary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(DateFormat('yyyy年M月d日').format(selectedDate),
                        style: AppText.button),
                    Text(
                      '${weekdays[selectedDate.weekday - 1]} · '
                      '${record?.location ?? '暂无记录'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (compact)
                IconButton(
                  tooltip: '查看所选日期详情',
                  onPressed: () => _showSelectedDateDetails(
                    context,
                    showAsDialog: showAsDialog,
                  ),
                  icon: const Icon(Icons.open_in_new),
                )
              else
                TextButton.icon(
                  onPressed: () => _showSelectedDateDetails(
                    context,
                    showAsDialog: showAsDialog,
                  ),
                  icon: const Icon(Icons.open_in_new, size: AppSpacing.lg),
                  label: const Text('查看详情'),
                ),
            ],
          ),
        );
      }),
    );
  }

  Future<void> _showSelectedDateDetails(
    BuildContext context, {
    required bool showAsDialog,
  }) async {
    final summary = _buildMonthRecords(context, _recordsInMonth(selectedDate));
    final content = ListView(
      padding: AppSpacing.cardComfortable,
      children: [
        selectedDateDetails,
        const SizedBox(height: AppSpacing.lg),
        summary,
      ],
    );
    final surfaces = AppSurfaces.of(context);
    if (showAsDialog) {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: surfaces.overlay,
          child: SizedBox(
            width: AppSizes.desktopTravelDetailsWidth,
            height: MediaQuery.sizeOf(context).height * 0.78,
            child: content,
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: surfaces.overlay,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.88,
        child: content,
      ),
    );
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCalendarToolbar(context),
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
          side: today ? BorderSide(color: scheme.primary) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onSelectDate(date),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${date.day}',
                    style: AppText.sectionTitle.copyWith(color: foreground)),
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
