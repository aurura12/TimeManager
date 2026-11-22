import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../models/travel_record.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/motion.dart';
import '../utils/platform_features.dart';
import '../utils/travel_table_columns.dart';
import 'motion_transitions.dart';

/// 列宽拖拽只认鼠标 / 触控笔：macOS 触控板双指横扫是 pan-zoom 事件，
/// 交给 DragRecognizer 会变成拖动（同 time_grid.dart 的坑）。
const Set<PointerDeviceKind> _columnResizeDevices = <PointerDeviceKind>{
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

/// 出行表格的表头与正文共用列宽、间隔和内边距。
///
/// 桌面端（且宿主接了 [onColumnWidthsChanged]）可以拖动列缝里的分隔条调整列宽：
/// 日期与地点是显式宽度，事件列取剩余；拖动期间只在本地预览，松手才上报。
class TravelRecordTable extends StatefulWidget {
  const TravelRecordTable({
    super.key,
    required this.records,
    required this.selectedDateKey,
    required this.onSelectDate,
    required this.actionsBuilder,
    this.enteringDateKey,
    this.removingDateKey,
    this.onEntranceEnd,
    this.onRemovalCollapsed,
    this.onRemovalInterrupted,
    this.dateColumnWidth,
    this.locationColumnWidth,
    this.onColumnWidthsChanged,
  });

  final List<TravelRecord> records;
  final String selectedDateKey;
  final ValueChanged<DateTime> onSelectDate;
  final Widget Function(TravelRecord record) actionsBuilder;

  /// 本次新增、需要播放一次入场动画的日期。
  final String? enteringDateKey;

  /// 正在播放退场动画、还没真正删除的日期。
  final String? removingDateKey;

  final VoidCallback? onEntranceEnd;
  final ValueChanged<TravelRecord>? onRemovalCollapsed;

  /// 退场动画被卸载打断时补发；页面把「待删」标记置空（删除不提交）。
  final ValueChanged<TravelRecord>? onRemovalInterrupted;

  /// 用户拖出来的日期列宽；null 表示用默认宽度（桌面 144 × 文字缩放）。
  final double? dateColumnWidth;

  /// 用户拖出来的地点列宽；null 表示剩余宽度按 2:3 分给地点与事件。
  final double? locationColumnWidth;

  /// 松手或双击复位时回调一次；两个参数都是 null 表示恢复默认。
  ///
  /// 只有桌面端且传了这个回调才渲染拖拽分隔条，移动端/窄窗口保持原样。
  final void Function(double? dateWidth, double? locationWidth)?
      onColumnWidthsChanged;

  @override
  State<TravelRecordTable> createState() => _TravelRecordTableState();
}

class _TravelRecordTableState extends State<TravelRecordTable> {
  /// 本次拖动的起手快照；dx 是累计位移，必须基于快照算，不能逐帧叠加。
  TravelColumnLayout? _dragBase;
  double? _previewDate;
  double? _previewLocation;
  int? _activeDivider;
  double _dragDx = 0;

  void _beginDrag(int divider, TravelColumnLayout layout) {
    setState(() {
      _activeDivider = divider;
      _dragBase = layout;
      _dragDx = 0;
      _previewDate = layout.date;
      _previewLocation = layout.location;
    });
  }

  void _updateDrag(int divider, double dx) {
    final base = _dragBase;
    if (base == null) return;
    _dragDx += dx;
    final next = dragTravelColumns(base, divider: divider, dx: _dragDx);
    setState(() {
      _previewDate = next.date;
      _previewLocation = next.location;
    });
  }

  void _endDrag() {
    final date = _previewDate;
    final location = _previewLocation;
    final moved = _dragDx.abs() > 0;
    setState(() {
      _activeDivider = null;
      _dragBase = null;
      _dragDx = 0;
      _previewDate = null;
      _previewLocation = null;
    });
    if (!moved || date == null || location == null) return;
    widget.onColumnWidthsChanged?.call(date, location);
  }

  void _cancelDrag() {
    setState(() {
      _activeDivider = null;
      _dragBase = null;
      _dragDx = 0;
      _previewDate = null;
      _previewLocation = null;
    });
  }

  void _resetWidths() {
    _cancelDrag();
    widget.onColumnWidthsChanged?.call(null, null);
  }

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
      final resizable = desktop && widget.onColumnWidthsChanged != null;
      final layout = resolveTravelColumns(
        maxWidth: constraints.maxWidth,
        desktop: desktop,
        textScale: textScale,
        dateOverride: _previewDate ?? widget.dateColumnWidth,
        locationOverride: _previewLocation ?? widget.locationColumnWidth,
      );
      final gap = travelColumnGap(desktop: desktop);
      final horizontalPadding = travelColumnHorizontalPadding(desktop: desktop);
      // 不可拖时沿用旧版日期列宽，保证移动端/窄窗口与改动前逐像素一致。
      final legacyDateWidth = ((desktop
                  ? AppSizes.desktopTravelDateColumnWidth
                  : AppSizes.travelDateColumnWidth) *
              textScale)
          .clamp(0.0, constraints.maxWidth / 3);

      Widget divider(int which, {String rowKey = ''}) => _TravelColumnDivider(
            key: ValueKey(rowKey.isEmpty
                ? 'travel-column-divider-$which'
                : 'travel-column-divider-$which-$rowKey'),
            width: gap,
            active: _activeDivider == which,
            showRestingLine: rowKey.isEmpty,
            tooltip: rowKey.isEmpty ? '拖动调整列宽；双击恢复默认' : null,
            onDragStart: () => _beginDrag(which, layout),
            onDragUpdate: (dx) => _updateDrag(which, dx),
            onDragEnd: _endDrag,
            onDragCancel: _cancelDrag,
            onReset: rowKey.isEmpty ? _resetWidths : null,
          );

      Widget columns({
        required Widget date,
        required Widget location,
        required Widget event,
        Widget? actions,
        String rowKey = '',
      }) {
        if (!resizable) {
          return Row(
            children: [
              SizedBox(width: legacyDateWidth, child: date),
              SizedBox(width: gap),
              Expanded(flex: AppSizes.travelLocationFlex, child: location),
              SizedBox(width: gap),
              Expanded(flex: AppSizes.travelEventFlex, child: event),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(width: AppSizes.minTapTarget, child: actions),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: layout.date, child: date),
            divider(1, rowKey: rowKey),
            SizedBox(width: layout.location, child: location),
            divider(2, rowKey: rowKey),
            Expanded(child: event),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(width: AppSizes.minTapTarget, child: actions),
          ],
        );
      }

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
              itemCount: widget.records.length,
              itemBuilder: (context, index) {
                final record = widget.records[index];
                final selected = record.dateKey == widget.selectedDateKey;
                final foreground =
                    selected ? scheme.onPrimaryContainer : scheme.onSurface;
                return ListItemRemoval(
                  key: ValueKey('travel-table-row-${record.dateKey}'),
                  removing: widget.removingDateKey == record.dateKey,
                  onCollapsed: () => widget.onRemovalCollapsed?.call(record),
                  onInterrupted: () =>
                      widget.onRemovalInterrupted?.call(record),
                  child: ListItemEntrance(
                    playing: widget.enteringDateKey == record.dateKey,
                    onEnd: widget.onEntranceEnd,
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected
                            ? context.wallpaperFill(scheme.primaryContainer)
                            : null,
                        border: Border(
                          bottom: BorderSide(color: surfaces.border),
                        ),
                      ),
                      child: InkWell(
                        onTap: () => widget.onSelectDate(record.date),
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
                              rowKey: record.dateKey,
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
                                  style:
                                      AppText.body.copyWith(color: foreground),
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
                              actions: widget.actionsBuilder(record),
                            ),
                          ),
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

/// 列分隔条：整行高的热区 + 居中的细竖线。
///
/// 只给桌面拖拽用；表头静止时显示淡线提供可发现性，行内只在 hover / 拖动时显形。
class _TravelColumnDivider extends StatefulWidget {
  const _TravelColumnDivider({
    super.key,
    required this.width,
    required this.active,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    this.showRestingLine = false,
    this.tooltip,
    this.onReset,
  });

  final double width;
  final bool active;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;

  /// 表头显示静止淡线；行内不显示，避免几十条竖线。
  final bool showRestingLine;
  final String? tooltip;

  /// 仅表头：双击恢复默认。
  final VoidCallback? onReset;

  @override
  State<_TravelColumnDivider> createState() => _TravelColumnDividerState();
}

class _TravelColumnDividerState extends State<_TravelColumnDivider> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final visible = widget.active || _hovered || widget.showRestingLine;

    Widget divider = MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        supportedDevices: _columnResizeDevices,
        onHorizontalDragStart: (_) => widget.onDragStart(),
        onHorizontalDragUpdate: (details) =>
            widget.onDragUpdate(details.delta.dx),
        onHorizontalDragEnd: (_) => widget.onDragEnd(),
        onHorizontalDragCancel: widget.onDragCancel,
        onDoubleTap: widget.onReset,
        child: SizedBox(
          width: widget.width,
          height: AppSizes.minTapTarget,
          child: Center(
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: appMotionDuration(context),
              child: Container(
                width: AppSizes.border,
                height: AppSizes.gridResizeBarHeight,
                decoration: BoxDecoration(
                  color: widget.active ? scheme.primary : surfaces.border,
                  borderRadius: AppRadius.gridAll,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip != null) {
      divider = Tooltip(message: tooltip, child: divider);
    }
    return divider;
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
