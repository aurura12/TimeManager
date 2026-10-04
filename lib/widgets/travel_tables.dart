import 'package:flutter/material.dart';

import '../models/travel_record.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/platform_features.dart';

/// 出行表格的表头与正文共用列宽、间隔和内边距。
class TravelRecordTable extends StatelessWidget {
  const TravelRecordTable({
    super.key,
    required this.records,
    required this.selectedDateKey,
    required this.onSelectDate,
    required this.actionsBuilder,
  });

  final List<TravelRecord> records;
  final String selectedDateKey;
  final ValueChanged<DateTime> onSelectDate;
  final Widget Function(TravelRecord record) actionsBuilder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final desktop = isDesktopPlatform &&
          constraints.maxWidth >= AppSizes.desktopTravelLayoutBreakpoint;
      final textScale =
          MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) /
              AppText.body.fontSize!;
      final dateWidth = ((desktop
                  ? AppSizes.desktopTravelDateColumnWidth
                  : AppSizes.travelDateColumnWidth) *
              textScale)
          .clamp(0.0, constraints.maxWidth / 3);
      final gap = desktop ? AppSpacing.xl : AppSpacing.sm;
      final horizontalPadding = desktop ? AppSpacing.lg : AppSpacing.xs;

      Widget columns({
        required Widget date,
        required Widget location,
        required Widget event,
        Widget? actions,
      }) =>
          Row(
            children: [
              SizedBox(width: dateWidth, child: date),
              SizedBox(width: gap),
              Expanded(flex: 2, child: location),
              SizedBox(width: gap),
              Expanded(flex: 3, child: event),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(width: AppSizes.minTapTarget, child: actions),
            ],
          );

      return Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: desktop ? AppSpacing.lg : AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: context.wallpaperFill(scheme.surfaceContainerHigh),
              borderRadius: AppRadius.controlAll,
            ),
            child: columns(
              date: const Text('日期', style: AppText.button),
              location: const Text('地点', style: AppText.button),
              event: const Text('事件', style: AppText.button),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Expanded(
            child: ListView.builder(
              itemCount: records.length,
              itemBuilder: (context, index) {
                final record = records[index];
                final selected = record.dateKey == selectedDateKey;
                final foreground =
                    selected ? scheme.onPrimaryContainer : scheme.onSurface;
                return Container(
                  key: ValueKey('travel-table-row-${record.dateKey}'),
                  decoration: BoxDecoration(
                    color: selected
                        ? context.wallpaperFill(scheme.primaryContainer)
                        : null,
                    border: Border(
                      bottom: BorderSide(color: surfaces.border),
                    ),
                  ),
                  child: InkWell(
                    onTap: () => onSelectDate(record.date),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: desktop
                            ? AppSizes.desktopTravelRowHeight
                            : AppSizes.minTapTarget,
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: horizontalPadding,
                          vertical: desktop ? AppSpacing.md : AppSpacing.xs,
                        ),
                        child: columns(
                          date: Text(
                            record.dateKey,
                            style: AppText.body.copyWith(color: foreground),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          location: Tooltip(
                            message: record.location,
                            child: Text(
                              record.location,
                              style: AppText.body.copyWith(color: foreground),
                              maxLines: desktop ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          event: Text(
                            record.event,
                            style: AppText.body.copyWith(
                              color: selected
                                  ? foreground
                                  : scheme.onSurfaceVariant,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          actions: actionsBuilder(record),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    });
  }
}

class TravelMonthlyTable extends StatelessWidget {
  const TravelMonthlyTable({
    super.key,
    required this.monthCounts,
    required this.locationsByMonth,
  });

  final List<MapEntry<String, int>> monthCounts;
  final Map<String, Set<String>> locationsByMonth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final desktop = isDesktopPlatform &&
          constraints.maxWidth >= AppSizes.desktopTravelLayoutBreakpoint;
      final scale =
          MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) /
              AppText.body.fontSize!;
      final monthWidth = ((desktop
                  ? AppSizes.desktopTravelDateColumnWidth
                  : AppSizes.travelMonthColumnWidth) *
              scale)
          .clamp(0.0, constraints.maxWidth / 3);
      final countWidth = ((desktop
                  ? AppSizes.desktopTravelCountColumnWidth
                  : AppSizes.travelCountColumnWidth) *
              scale)
          .clamp(0.0, constraints.maxWidth / 5);
      final gap = desktop ? AppSpacing.xl : AppSpacing.sm;
      final padding = EdgeInsets.symmetric(
        horizontal: desktop ? AppSpacing.lg : AppSpacing.md,
        vertical: AppSpacing.md,
      );
      String locationsText(String month) {
        final locations = locationsByMonth[month]?.toList() ?? [];
        locations.sort();
        return locations.join('、');
      }

      Widget row({
        required String month,
        required String count,
        required String locations,
        bool header = false,
      }) =>
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: desktop
                  ? AppSizes.desktopTravelRowHeight
                  : AppSizes.minTapTarget,
            ),
            child: Padding(
              padding: padding,
              child: Row(
                children: [
                  SizedBox(
                    width: monthWidth,
                    child: Text(month,
                        style: header ? AppText.button : AppText.body),
                  ),
                  SizedBox(width: gap),
                  SizedBox(
                    width: countWidth,
                    child: Text(count,
                        textAlign: TextAlign.end,
                        style: header ? AppText.button : AppText.body),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: Text(
                      locations,
                      style: header
                          ? AppText.button
                          : AppText.body
                              .copyWith(color: scheme.onSurfaceVariant),
                      maxLines: desktop ? null : 2,
                      overflow: desktop
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );

      return Container(
        decoration: BoxDecoration(
          color: surfaces.card,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: surfaces.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(
              color: context.wallpaperFill(scheme.surfaceContainerHigh),
              child:
                  row(month: '月份', count: '次数', locations: '地点', header: true),
            ),
            for (final entry in monthCounts)
              Container(
                key: ValueKey('travel-month-row-${entry.key}'),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: surfaces.border)),
                ),
                child: row(
                  month: entry.key,
                  count: '${entry.value}',
                  locations: locationsText(entry.key),
                ),
              ),
          ],
        ),
      );
    });
  }
}
