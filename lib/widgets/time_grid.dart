import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/event_label_style.dart';
import '../models/time_slot.dart';
import '../models/time_slot_resize.dart';
import '../providers/event_label_style_provider.dart';
import '../providers/time_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/platform_features.dart';
import '../utils/time_block_resize.dart';
import '../utils/time_slot_segment.dart';
import 'event_label_text.dart';

/// 时间网格的渲染与手势层。
///
/// 网格只订阅当前日期和时间块版本；拖选状态仍由 HomeScreen 持有，
/// 以便保持现有分类侧栏交互不变。
///
/// 刷子模式（[brushMode]）下网格改用外层 [Listener] 接管指针：行内原有的
/// 点选 / 拖动选择 / 双击删除全部让位，避免与刷子手势抢同一个指针。
///
/// 拖拽边界调时长同样走外层 [Listener] 而不是边缘子 GestureDetector：
/// 拖拽预览会改变 Row 的 children 数量，段的 Element 会被销毁重建，
/// 挂在段上的手势识别器会丢指针导致拖动中断。
class TimeGrid extends StatefulWidget {
  const TimeGrid({
    super.key,
    required this.gridKey,
    required this.controller,
    required this.dragStartIndex,
    required this.dragEndIndex,
    required this.onTapDown,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onRemoveSlot,
    this.date,
    this.brushMode = false,
    this.brushPreviewIndices = const <int>{},
    this.onBrushPointerDown,
    this.onBrushPointerMove,
    this.onBrushPointerUp,
    this.onBrushPointerCancel,
    this.readOnly = false,
    this.onResizeTimeBlock,
  });

  final GlobalKey gridKey;
  final ScrollController controller;
  final int? dragStartIndex;
  final int? dragEndIndex;
  final ValueChanged<Offset> onTapDown;
  final ValueChanged<Offset> onPanStart;
  final ValueChanged<Offset> onPanUpdate;
  final ValueChanged<int> onRemoveSlot;

  /// 要渲染的日期；为 null 时渲染当前日期（保持原有行为）
  final DateTime? date;

  /// 刷子模式：行内手势全部关闭，只保留 [Listener] 上报的指针事件。
  final bool brushMode;

  /// 本次刷子手势将要写入的槽位，手势结束前只做预览、不落数据。
  final Set<int> brushPreviewIndices;

  /// 刷子手势回调。四者全为 null 时不安装外层 [Listener]，
  /// 交给调用方自己处理（Windows 三列由 `_DayGrid` 上报日期 + 索引）。
  final ValueChanged<Offset>? onBrushPointerDown;
  final ValueChanged<Offset>? onBrushPointerMove;
  final VoidCallback? onBrushPointerUp;
  final VoidCallback? onBrushPointerCancel;

  /// 远程视图等只读态：不提供拖拽把手
  final bool readOnly;

  /// 拖拽边界提交回调；为 null 时不提供该能力
  final ValueChanged<TimeSlotResizeRequest>? onResizeTimeBlock;

  bool get _handlesBrushGestures =>
      onBrushPointerDown != null ||
      onBrushPointerMove != null ||
      onBrushPointerUp != null ||
      onBrushPointerCancel != null;

  bool get resizeEnabled =>
      onResizeTimeBlock != null && !readOnly && !brushMode;

  @override
  State<TimeGrid> createState() => _TimeGridState();
}

/// 一次拖拽会话：拖拽期间只在本地预览，松手才提交。
class _ResizeSession {
  _ResizeSession({
    required this.pointer,
    required this.isMouse,
    required this.date,
    required this.edge,
    required this.originalStart,
    required this.originalEnd,
    required this.label,
    required this.categoryId,
    required this.color,
    required this.columnWidth,
    required this.targetIndex,
  });

  final int pointer;
  final bool isMouse;
  final DateTime date;
  final TimeSlotResizeEdge edge;
  final int originalStart;
  final int originalEnd;
  final String label;
  final String? categoryId;
  final Color color;
  final double columnWidth;

  int targetIndex;
  double accumDx = 0;
  double accumDy = 0;
  bool moved = false;

  int get originalBoundary =>
      edge == TimeSlotResizeEdge.start ? originalStart : originalEnd;

  int get newStart =>
      edge == TimeSlotResizeEdge.start ? targetIndex : originalStart;

  int get newEnd => edge == TimeSlotResizeEdge.end ? targetIndex : originalEnd;

  TimeSlotResizeRequest toRequest() => TimeSlotResizeRequest(
        date: date,
        anchorIndex: originalBoundary,
        edge: edge,
        targetIndex: targetIndex,
        expectedStart: originalStart,
        expectedEnd: originalEnd,
        expectedLabel: label,
        expectedCategoryId: categoryId,
        expectedColor: color,
      );
}

/// 一个时间块段的把手信息
class _GridResizeTarget {
  const _GridResizeTarget({
    required this.date,
    required this.blockStart,
    required this.blockEnd,
    required this.label,
    required this.categoryId,
    required this.color,
    required this.columnWidth,
    required this.active,
  });

  final DateTime date;
  final int blockStart;
  final int blockEnd;
  final String label;
  final String? categoryId;
  final Color color;
  final double columnWidth;

  /// 移动端：这个块当前是否被点选（未点选不出现把手）
  final bool active;
}

class _TimeGridState extends State<TimeGrid> {
  _ResizeSession? _resize;

  /// 鼠标悬停在哪条边上（key 形如 `dateKey:start:index`）
  String? _hoverEdgeKey;

  /// 在把手上点了一下但没拖动时，别把已点选的块取消掉
  bool _suppressTapOnce = false;

  bool _isHighlighted(int index) {
    final start = widget.dragStartIndex;
    final end = widget.dragEndIndex;
    if (start == null || end == null) return false;
    final from = start < end ? start : end;
    final to = start < end ? end : start;
    return index >= from && index <= to;
  }

  bool _isBrushPreview(int index) => widget.brushPreviewIndices.contains(index);

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _dateKeyOf(DateTime date) =>
      '${date.year}-${date.month}-${date.day}';

  /// 把「0 点起的分钟数」格式化成 HH:mm，用于长按气泡里的时间段。
  String _clockOf(int minutes) {
    final normalized = minutes % (24 * 60);
    final hour = (normalized ~/ 60).toString().padLeft(2, '0');
    final minute = (normalized % 60).toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  int? get _selectedIndex {
    final start = widget.dragStartIndex;
    final end = widget.dragEndIndex;
    if (start == null || end == null || start != end) return null;
    return start;
  }

  /// 当前点选的块范围（移动端据此显示把手）
  TimeBlockRange? _activeBlockRange(List<TimeSlot> sourceSlots) {
    final index = _selectedIndex;
    if (index == null) return null;
    return findTimeBlockRange(sourceSlots, index);
  }

  /// 拖拽中的临时预览：只影响渲染，不写数据
  List<TimeSlot> _previewSlots(DateTime date, List<TimeSlot> sourceSlots) {
    final session = _resize;
    if (session == null || !_sameDay(session.date, date)) return sourceSlots;
    if (session.newStart == session.originalStart &&
        session.newEnd == session.originalEnd) {
      return sourceSlots;
    }
    return applyTimeBlockResizePreview(
      slots: sourceSlots,
      originalStart: session.originalStart,
      originalEnd: session.originalEnd,
      newStart: session.newStart,
      newEnd: session.newEnd,
      label: session.label,
      categoryId: session.categoryId,
      color: session.color,
    );
  }

  void _startResize(
    PointerDownEvent event,
    _GridResizeTarget target,
    TimeSlotResizeEdge edge,
  ) {
    if (!widget.resizeEnabled || _resize != null) return;
    if ((event.buttons & kPrimaryButton) == 0) return;
    final isMouse = event.kind == PointerDeviceKind.mouse;
    // 触摸 / 触控笔必须先点选块，鼠标可以直接拖
    if (!isMouse && !target.active) return;

    _suppressTapOnce = false;
    setState(() {
      _resize = _ResizeSession(
        pointer: event.pointer,
        isMouse: isMouse,
        date: target.date,
        edge: edge,
        originalStart: target.blockStart,
        originalEnd: target.blockEnd,
        label: target.label,
        categoryId: target.categoryId,
        color: target.color,
        columnWidth: target.columnWidth,
        targetIndex: edge == TimeSlotResizeEdge.start
            ? target.blockStart
            : target.blockEnd,
      );
    });
  }

  void _onGridPointerMove(PointerMoveEvent event) {
    final session = _resize;
    if (session == null || session.pointer != event.pointer) return;

    session.accumDx += event.delta.dx;
    session.accumDy += event.delta.dy;
    if (session.accumDx.abs() + session.accumDy.abs() > 2) {
      session.moved = true;
    }

    // 横向半列（约 27px）= 1 格 = 10 分钟；纵向满一行 = 6 格 = 1 小时。
    // 两者叠加，等价于把二维位移投影到网格的线性索引 row * 6 + col。
    final dxCols = (session.accumDx / session.columnWidth).round();
    final dyRows = (session.accumDy / AppSizes.gridRow).truncate();
    final next = clampTimeBlockResizeTarget(
      edge: session.edge,
      originalStart: session.originalStart,
      originalEnd: session.originalEnd,
      targetIndex: session.originalBoundary + dxCols + dyRows * 6,
    );
    if (next != session.targetIndex) {
      final target = next;
      setState(() => session.targetIndex = target);
    }
  }

  void _onGridPointerUp(PointerUpEvent event) {
    final session = _resize;
    if (session == null || session.pointer != event.pointer) return;

    final commit =
        session.moved && session.targetIndex != session.originalBoundary;
    final request = commit ? session.toRequest() : null;
    final suppressTap = !commit && !session.isMouse;

    // 必须先清：行级 onTapDown 在指针 up 之后的手势竞技场结算里才触发，
    // 清掉后「按一下不拖」仍然是普通的点选 / 双击删除。
    setState(() {
      _resize = null;
      if (suppressTap) _suppressTapOnce = true;
    });
    if (request != null) widget.onResizeTimeBlock?.call(request);
  }

  void _onGridPointerCancel(PointerCancelEvent event) {
    final session = _resize;
    if (session == null || session.pointer != event.pointer) return;
    setState(() => _resize = null);
  }

  void _setHoverEdge(String? key) {
    if (_hoverEdgeKey == key) return;
    setState(() => _hoverEdgeKey = key);
  }

  @override
  Widget build(BuildContext context) {
    return Selector<TimeProvider, ({int slotsRevision, DateTime currentDate})>(
      selector: (_, provider) => (
        slotsRevision: provider.slotsRevision,
        currentDate: provider.currentDate,
      ),
      builder: (context, _, __) {
        final provider = context.read<TimeProvider>();
        final resolvedDate = widget.date ?? provider.currentDate;
        final sourceSlots = widget.date == null
            ? provider.slots
            : provider.slotsForDate(widget.date!);
        // 预览每帧只算一次，不要在每行里重复复制 144 个槽位
        final displaySlots = _previewSlots(resolvedDate, sourceSlots);
        final activeRange = _activeBlockRange(sourceSlots);

        final grid = ListView.builder(
          key: widget.gridKey,
          controller: widget.controller,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          itemCount: 24,
          itemExtent: AppSizes.gridRow,
          itemBuilder: (context, hour) => _buildGridRow(
            context,
            hour,
            provider,
            resolvedDate,
            displaySlots,
            activeRange,
          ),
        );

        if (!widget._handlesBrushGestures && !widget.resizeEnabled) {
          return grid;
        }

        Widget result = grid;
        if (widget._handlesBrushGestures) {
          // 整列装一个 Listener：拖动跨越不同小时行不会丢手势，
          // 也不需要每经过一个格子就回调一次 Provider。
          result = Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) =>
                widget.onBrushPointerDown?.call(event.position),
            onPointerMove: (event) =>
                widget.onBrushPointerMove?.call(event.position),
            onPointerUp: (_) => widget.onBrushPointerUp?.call(),
            onPointerCancel: (_) => widget.onBrushPointerCancel?.call(),
            child: result,
          );
        }
        if (widget.resizeEnabled) {
          result = Listener(
            behavior: HitTestBehavior.opaque,
            onPointerMove: _onGridPointerMove,
            onPointerUp: _onGridPointerUp,
            onPointerCancel: _onGridPointerCancel,
            child: result,
          );
        }
        if (widget.resizeEnabled && _resize != null) {
          // 拖动时指针可能离开把手，光标保持 resize 不闪回默认
          result = MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: result,
          );
        }
        return result;
      },
    );
  }

  Widget _buildGridRow(
    BuildContext context,
    int hour,
    TimeProvider provider,
    DateTime resolvedDate,
    List<TimeSlot> displaySlots,
    TimeBlockRange? activeRange,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = RepaintBoundary(
          child: _buildGridRowContent(
            context,
            hour,
            provider,
            resolvedDate,
            displaySlots,
            activeRange,
            constraints.maxWidth,
          ),
        );
        if (widget.brushMode) {
          // 刷子手势由外层 Listener 独占，行内不再参与手势竞技场
          return content;
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            if (_resize != null) return;
            if (_suppressTapOnce) {
              _suppressTapOnce = false;
              return;
            }
            widget.onTapDown(details.globalPosition);
          },
          onDoubleTapDown: (details) {
            if (_resize != null) return;
            final width = constraints.maxWidth;
            final column =
                (details.localPosition.dx / (width / 6)).floor().clamp(0, 5);
            widget.onRemoveSlot(hour * 6 + column);
          },
          onDoubleTap: () {},
          onPanStart: (details) {
            if (_resize != null) return;
            widget.onPanStart(details.globalPosition);
          },
          onPanUpdate: (details) {
            if (_resize != null) return;
            widget.onPanUpdate(details.globalPosition);
          },
          child: content,
        );
      },
    );
  }

  Widget _buildGridRowContent(
    BuildContext context,
    int hour,
    TimeProvider provider,
    DateTime resolvedDate,
    List<TimeSlot> daySlots,
    TimeBlockRange? activeRange,
    double rowWidth,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final highlightColor = colorScheme.primary.withValues(alpha: 0.28);
    // 空白格用主题的次级表面色，浅色下比原灰色更浅，深色下不刺眼
    final emptyCellColor = surfaces.gridEmpty;
    // 刷子预览：品牌绿（primary）的淡填充 + 实色描边，表示"松手后会写入这里"
    final brushPreviewFill =
        AppSemanticColors.tint(colorScheme.primary, emptyCellColor, 0.35);
    final brushPreviewBorder = colorScheme.primary;
    // 事件名显示方式：本机偏好，未注册 Provider 时按默认两行
    final labelStyle = context.watch<EventLabelStyleProvider?>()?.style ??
        EventLabelStyle.twoLines;
    // 气泡里要带分类名，先按 id 建一次索引，避免每块都线性查找
    final categoryNames = <String, String>{
      for (final category in provider.categories) category.id: category.name,
    };
    final columnWidth = rowWidth / 6;
    final session = _resize;

    return Container(
      height: AppSizes.gridRow,
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: () {
          final segments = <Widget>[];
          var minute = 0;
          while (minute < 6) {
            final index = hour * 6 + minute;
            final slot = daySlots[index];
            final label = slot.label;

            if (label != null && slot.color != null) {
              var span = 1;
              while (minute + span < 6 &&
                  canJoinTimeSlots(
                    slot,
                    daySlots[hour * 6 + minute + span],
                  )) {
                span++;
              }
              var highlighted = false;
              var preview = false;
              for (var k = 0; k < span; k++) {
                if (_isHighlighted(hour * 6 + minute + k)) highlighted = true;
                if (_isBrushPreview(hour * 6 + minute + k)) preview = true;
              }

              final startMinutes = hour * 60 + minute * 10;
              final categoryName = slot.categoryId == null
                  ? null
                  : categoryNames[slot.categoryId];
              final detail = categoryName == null
                  ? '${_clockOf(startMinutes)}–${_clockOf(startMinutes + span * 10)}'
                  : '${_clockOf(startMinutes)}–${_clockOf(startMinutes + span * 10)}'
                      ' · $categoryName';
              final labelColor = highlighted
                  ? colorScheme.onSurface
                  : AppSemanticColors.onColor(slot.color!,
                      over: surfaces.page);

              final blockRange = findTimeBlockRange(daySlots, index);
              final resizingThisBlock = session != null &&
                  _sameDay(session.date, resolvedDate) &&
                  blockRange != null &&
                  blockRange.start == session.newStart &&
                  blockRange.end == session.newEnd;
              final blockActive = resizingThisBlock ||
                  (activeRange != null &&
                      blockRange != null &&
                      activeRange.start == blockRange.start &&
                      activeRange.end == blockRange.end);
              final showHandles = widget.resizeEnabled &&
                  !slot.isFromCalendar &&
                  blockRange != null &&
                  (isDesktopPlatform || blockActive);
              final showLeft = showHandles && blockRange.start == index;
              final showRight =
                  showHandles && blockRange.end == index + span - 1;
              final segmentWidth = columnWidth * span;
              final hitWidth = math.min(
                isDesktopPlatform
                    ? AppSizes.gridResizeMouseEdge
                    : AppSizes.gridResizeTouchEdge,
                segmentWidth * 0.4,
              );
              final target = _GridResizeTarget(
                date: resolvedDate,
                blockStart: blockRange?.start ?? index,
                blockEnd: blockRange?.end ?? index + span - 1,
                label: label,
                categoryId: slot.categoryId,
                color: slot.color!,
                columnWidth: columnWidth,
                active: blockActive,
              );
              final edgeKeyBase = '${_dateKeyOf(resolvedDate)}:$hour:$index';

              final block = Container(
                margin: EdgeInsets.only(
                  top: 1,
                  bottom: 1,
                  left: _shouldBridgeLeft(daySlots, index) ? 0 : 1,
                  right:
                      _shouldBridgeRight(daySlots, index + span - 1) ? 0 : 1,
                ),
                decoration: BoxDecoration(
                  // 刷子预览不改已有事件的颜色，只在外圈加一道主色描边
                  color: highlighted ? highlightColor : slot.color!,
                  border: preview
                      ? Border.all(color: brushPreviewBorder, width: 2)
                      : null,
                  borderRadius: _computeSegmentBorderRadius(
                      daySlots, hour, minute, span, highlighted),
                ),
                // 极端字体放大时两行也放不下，裁掉而不是盖到相邻块
                clipBehavior: Clip.hardEdge,
                child: Center(
                  child: EventLabelText(
                    text: label,
                    maxLines: labelStyle.maxLines,
                    // 气泡补上时间段和分类：长按看到的信息比"两行"更多
                    detail: detail,
                    // 刷子模式下整列由外层 Listener 接管指针
                    enableTooltip: !widget.brushMode,
                    style: AppText.gridLabel.copyWith(color: labelColor),
                  ),
                ),
              );

              if (!showLeft && !showRight) {
                segments.add(Expanded(
                  flex: span,
                  child: block,
                ));
                minute += span;
                continue;
              }

              segments.add(Expanded(
                flex: span,
                // 把手是背景层的兄弟节点，不会被块的 hardEdge 裁掉
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(child: block),
                    if (showLeft)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: hitWidth,
                        child: _GridResizeHandle(
                          key: ValueKey('grid-resize-start-$edgeKeyBase'),
                          edge: TimeSlotResizeEdge.start,
                          showBar: _shouldShowBar(
                            '$edgeKeyBase:start',
                            blockActive: blockActive,
                            active: session != null &&
                                session.edge == TimeSlotResizeEdge.start &&
                                _sameDay(session.date, resolvedDate) &&
                                session.newStart == blockRange.start,
                          ),
                          color: labelColor,
                          onPointerDown: (event) =>
                              _startResize(event, target, TimeSlotResizeEdge.start),
                          onHoverChanged: (hovering) => _setHoverEdge(
                              hovering ? '$edgeKeyBase:start' : null),
                        ),
                      ),
                    if (showRight)
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        width: hitWidth,
                        child: _GridResizeHandle(
                          key: ValueKey('grid-resize-end-$edgeKeyBase'),
                          edge: TimeSlotResizeEdge.end,
                          showBar: _shouldShowBar(
                            '$edgeKeyBase:end',
                            blockActive: blockActive,
                            active: session != null &&
                                session.edge == TimeSlotResizeEdge.end &&
                                _sameDay(session.date, resolvedDate) &&
                                session.newEnd == blockRange.end,
                          ),
                          color: labelColor,
                          onPointerDown: (event) =>
                              _startResize(event, target, TimeSlotResizeEdge.end),
                          onHoverChanged: (hovering) => _setHoverEdge(
                              hovering ? '$edgeKeyBase:end' : null),
                        ),
                      ),
                  ],
                ),
              ));
              minute += span;
            } else {
              final highlighted = _isHighlighted(index);
              final preview = _isBrushPreview(index);
              segments.add(Expanded(
                child: Container(
                  margin: const EdgeInsets.all(1),
                  decoration: BoxDecoration(
                    color: preview
                        ? brushPreviewFill
                        : (highlighted ? highlightColor : emptyCellColor),
                    border: preview
                        ? Border.all(color: brushPreviewBorder, width: 2)
                        : null,
                    borderRadius: AppRadius.gridAll,
                  ),
                  child: const SizedBox.expand(),
                ),
              ));
              minute++;
            }
          }
          return segments;
        }(),
      ),
    );
  }

  bool _shouldShowBar(
    String edgeKey, {
    required bool blockActive,
    required bool active,
  }) {
    if (active) return true;
    if (isDesktopPlatform) {
      // 桌面端悬停才显示竖条，避免整屏都是小竖线
      return _hoverEdgeKey == edgeKey;
    }
    return blockActive;
  }

  bool _shouldBridgeLeft(List<TimeSlot> daySlots, int index) =>
      index % 6 != 0 && canJoinTimeSlots(daySlots[index - 1], daySlots[index]);

  bool _shouldBridgeRight(List<TimeSlot> daySlots, int index) =>
      index % 6 != 5 && canJoinTimeSlots(daySlots[index], daySlots[index + 1]);

  BorderRadius _computeSegmentBorderRadius(List<TimeSlot> daySlots, int hour,
      int startMinute, int span, bool isHighlighted) {
    if (isHighlighted) return AppRadius.gridAll;
    final startIndex = hour * 6 + startMinute;
    final endIndex = startIndex + span - 1;
    final leftRounded = startIndex % 6 == 0 ||
        startIndex == 0 ||
        !canJoinTimeSlots(daySlots[startIndex - 1], daySlots[startIndex]);
    final rightRounded = endIndex % 6 == 5 ||
        endIndex >= daySlots.length - 1 ||
        !canJoinTimeSlots(daySlots[endIndex], daySlots[endIndex + 1]);
    // 相接的一侧圆角必须为 0（AppRadius.joined），否则连续时间块会出现缺口
    return BorderRadius.only(
      topLeft: leftRounded ? AppRadius.rGrid : AppRadius.rJoined,
      bottomLeft: leftRounded ? AppRadius.rGrid : AppRadius.rJoined,
      topRight: rightRounded ? AppRadius.rGrid : AppRadius.rJoined,
      bottomRight: rightRounded ? AppRadius.rGrid : AppRadius.rJoined,
    );
  }
}

/// 时间块边缘的可拖拽把手：透明热区 + 一条可见竖条。
class _GridResizeHandle extends StatelessWidget {
  const _GridResizeHandle({
    super.key,
    required this.edge,
    required this.showBar,
    required this.color,
    required this.onPointerDown,
    required this.onHoverChanged,
  });

  final TimeSlotResizeEdge edge;
  final bool showBar;
  final Color color;
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<bool> onHoverChanged;

  @override
  Widget build(BuildContext context) {
    final isStart = edge == TimeSlotResizeEdge.start;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: onPointerDown,
        child: Align(
          alignment: isStart ? Alignment.centerLeft : Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(
              left: isStart ? AppSpacing.xs : 0,
              right: isStart ? 0 : AppSpacing.xs,
            ),
            child: AnimatedOpacity(
              opacity: showBar ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Container(
                width: AppSizes.gridResizeBarWidth,
                height: AppSizes.gridResizeBarHeight,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: AppRadius.gridAll,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
