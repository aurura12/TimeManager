import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/time_slot.dart';
import '../providers/time_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/time_slot_segment.dart';

/// 时间网格的渲染与手势层。
///
/// 网格只订阅当前日期和时间块版本；拖选状态仍由 HomeScreen 持有，
/// 以便本阶段保持现有分类侧栏交互不变。
///
/// 刷子模式（[brushMode]）下网格改用外层 [Listener] 接管指针：行内原有的
/// 点选 / 拖动选择 / 双击删除全部让位，避免与刷子手势抢同一个指针。
class TimeGrid extends StatelessWidget {
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

  bool get _handlesBrushGestures =>
      onBrushPointerDown != null ||
      onBrushPointerMove != null ||
      onBrushPointerUp != null ||
      onBrushPointerCancel != null;

  bool _isHighlighted(int index) {
    if (dragStartIndex == null || dragEndIndex == null) return false;
    final start =
        dragStartIndex! < dragEndIndex! ? dragStartIndex! : dragEndIndex!;
    final end =
        dragStartIndex! < dragEndIndex! ? dragEndIndex! : dragStartIndex!;
    return index >= start && index <= end;
  }

  bool _isBrushPreview(int index) => brushPreviewIndices.contains(index);

  @override
  Widget build(BuildContext context) {
    return Selector<TimeProvider, ({int slotsRevision, DateTime currentDate})>(
      selector: (_, provider) => (
        slotsRevision: provider.slotsRevision,
        currentDate: provider.currentDate,
      ),
      builder: (context, _, __) {
        final provider = context.read<TimeProvider>();
        final grid = ListView.builder(
          key: gridKey,
          controller: controller,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          itemCount: 24,
          itemExtent: AppSizes.gridRow,
          itemBuilder: (context, hour) =>
              _buildGridRow(context, hour, provider),
        );
        if (!_handlesBrushGestures) return grid;
        // 整列装一个 Listener：拖动跨越不同小时行不会丢手势，
        // 也不需要每经过一个格子就回调一次 Provider。
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) => onBrushPointerDown?.call(event.position),
          onPointerMove: (event) => onBrushPointerMove?.call(event.position),
          onPointerUp: (_) => onBrushPointerUp?.call(),
          onPointerCancel: (_) => onBrushPointerCancel?.call(),
          child: grid,
        );
      },
    );
  }

  Widget _buildGridRow(BuildContext context, int hour, TimeProvider provider) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = RepaintBoundary(
          child: _buildGridRowContent(context, hour, provider),
        );
        if (brushMode) {
          // 刷子手势由外层 Listener 独占，行内不再参与手势竞技场
          return content;
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => onTapDown(details.globalPosition),
          onDoubleTapDown: (details) {
            final width = constraints.maxWidth;
            final column =
                (details.localPosition.dx / (width / 6)).floor().clamp(0, 5);
            onRemoveSlot(hour * 6 + column);
          },
          onDoubleTap: () {},
          onPanStart: (details) => onPanStart(details.globalPosition),
          onPanUpdate: (details) => onPanUpdate(details.globalPosition),
          child: content,
        );
      },
    );
  }

  Widget _buildGridRowContent(
      BuildContext context, int hour, TimeProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final highlightColor = colorScheme.primary.withValues(alpha: 0.28);
    // 空白格用主题的次级表面色，浅色下比原灰色更浅，深色下不刺眼
    final emptyCellColor = surfaces.gridEmpty;
    // 刷子预览：品牌绿（primary）的淡填充 + 实色描边，表示"松手后会写入这里"
    final brushPreviewFill =
        AppSemanticColors.tint(colorScheme.primary, emptyCellColor, 0.35);
    final brushPreviewBorder = colorScheme.primary;
    final daySlots =
        date == null ? provider.slots : provider.slotsForDate(date!);

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

              segments.add(Expanded(
                flex: span,
                child: Container(
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
                  child: Center(
                    child: Text(
                      label,
                      style: AppText.gridLabel.copyWith(
                        // 高亮时底色是主色半透明，未高亮时是分类实色。
                        // 分类色理论上已被 opaque() 收成不透明，这里仍传底面：
                        // 万一有历史脏数据（8 位 ARGB 存下来的半透明色）也不会算错色。
                        color: highlighted
                            ? colorScheme.onSurface
                            : AppSemanticColors.onColor(slot.color!,
                                over: surfaces.page),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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
