import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/time_slot.dart';
import '../providers/time_provider.dart';

/// 时间网格的渲染与手势层。
///
/// 网格只订阅当前日期和时间块版本；拖选状态仍由 HomeScreen 持有，
/// 以便本阶段保持现有分类侧栏交互不变。
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

  bool _isHighlighted(int index) {
    if (dragStartIndex == null || dragEndIndex == null) return false;
    final start = dragStartIndex! < dragEndIndex! ? dragStartIndex! : dragEndIndex!;
    final end = dragStartIndex! < dragEndIndex! ? dragEndIndex! : dragStartIndex!;
    return index >= start && index <= end;
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
        return ListView.builder(
          key: gridKey,
          controller: controller,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: 24,
          itemExtent: 45,
          itemBuilder: (context, hour) => _buildGridRow(context, hour, provider),
        );
      },
    );
  }

  Widget _buildGridRow(BuildContext context, int hour, TimeProvider provider) {
    return LayoutBuilder(
      builder: (context, constraints) {
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
          child: RepaintBoundary(
            child: _buildGridRowContent(context, hour, provider),
          ),
        );
      },
    );
  }

  Widget _buildGridRowContent(
      BuildContext context, int hour, TimeProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final highlightColor = colorScheme.primary.withValues(alpha: 0.28);
    final emptyCellColor = isDark
        ? colorScheme.surfaceContainerHigh
        : const Color.fromARGB(255, 188, 186, 186);
    final daySlots =
        date == null ? provider.slots : provider.slotsForDate(date!);

    return Container(
      height: 45,
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
                  daySlots[hour * 6 + minute + span].label == label) {
                span++;
              }
              var highlighted = false;
              for (var k = 0; k < span; k++) {
                if (_isHighlighted(hour * 6 + minute + k)) {
                  highlighted = true;
                  break;
                }
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
                    color: highlighted ? highlightColor : slot.color!,
                    borderRadius: _computeSegmentBorderRadius(
                        daySlots, hour, minute, span, highlighted),
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ));
              minute += span;
            } else {
              final highlighted = _isHighlighted(index);
              segments.add(Expanded(
                child: Container(
                  margin: const EdgeInsets.all(1),
                  decoration: BoxDecoration(
                    color: highlighted ? highlightColor : emptyCellColor,
                    borderRadius: BorderRadius.circular(4),
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
      index % 6 != 0 &&
      daySlots[index].label != null &&
      daySlots[index].label == daySlots[index - 1].label;

  bool _shouldBridgeRight(List<TimeSlot> daySlots, int index) =>
      index % 6 != 5 &&
      daySlots[index].label != null &&
      daySlots[index].label == daySlots[index + 1].label;

  BorderRadius _computeSegmentBorderRadius(List<TimeSlot> daySlots, int hour,
      int startMinute, int span, bool isHighlighted) {
    if (isHighlighted) return BorderRadius.circular(4);
    final startIndex = hour * 6 + startMinute;
    final endIndex = startIndex + span - 1;
    final leftRounded = startIndex % 6 == 0 ||
        startIndex == 0 ||
        daySlots[startIndex].label != daySlots[startIndex - 1].label;
    final rightRounded = endIndex % 6 == 5 ||
        endIndex >= daySlots.length - 1 ||
        daySlots[endIndex].label != daySlots[endIndex + 1].label;
    return BorderRadius.only(
      topLeft: leftRounded ? const Radius.circular(4) : Radius.zero,
      bottomLeft: leftRounded ? const Radius.circular(4) : Radius.zero,
      topRight: rightRounded ? const Radius.circular(4) : Radius.zero,
      bottomRight: rightRounded ? const Radius.circular(4) : Radius.zero,
    );
  }
}
