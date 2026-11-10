import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import '../theme/app_tokens.dart';

/// 菜单栏转盘浮层相对选区的落位方式。
enum MenuBarDialSide {
  /// 贴在选区右侧，垂直居中对齐选区
  right,

  /// 贴在选区左侧，垂直居中对齐选区
  left,

  /// 贴在选区下方，水平居中
  below,

  /// 贴在选区上方，水平居中
  above,

  /// 四面都放不下：按左右剩余空间取大的一侧，夹进边界（会盖住选区）
  clamped,
}

/// 一次落位的结果。
class MenuBarDialPlacement {
  const MenuBarDialPlacement({
    required this.rect,
    required this.side,
    required this.requested,
    required this.overlapsSelection,
  });

  /// 浮层最终矩形，已夹在可视区内；视口太小时会小于 [requested]。
  final Rect rect;
  final MenuBarDialSide side;

  /// 调用方请求的尺寸（tokens 里的 264×308）。
  final Size requested;

  /// 浮层是否盖住了选区（只有 [MenuBarDialSide.clamped] 会为 true）。
  final bool overlapsSelection;

  /// 视口太小被压缩过。
  bool get shrunk =>
      (rect.width - requested.width).abs() > 0.5 ||
      (rect.height - requested.height).abs() > 0.5;
}

/// 选区是否还有一部分留在可视区里；完全滚出去时调用方不画浮层。
bool menuBarSelectionVisible(Rect selection, Size bounds) {
  return selection.right > 0 &&
      selection.left < bounds.width &&
      selection.bottom > 0 &&
      selection.top < bounds.height;
}

/// 把转盘浮层摆到选区旁边。
///
/// 顺序是「右 → 左 → 下 → 上 → 夹进边界」：面板内容区只有 368pt 宽，264pt 的
/// 浮层大多放不到选区左右，于是落到上方或下方；只有四周都挤不下时才允许压住
/// 选区（[MenuBarDialPlacement.overlapsSelection]），靠 hint 行里的时间段兜底。
MenuBarDialPlacement placeMenuBarDial({
  required Rect selection,
  required Size bounds,
  required Size dialSize,
  double gap = AppSpacing.sm,
  double margin = AppSpacing.sm,
}) {
  final availableWidth = math.max(0.0, bounds.width - margin * 2);
  final availableHeight = math.max(0.0, bounds.height - margin * 2);
  final width = math.min(dialSize.width, availableWidth);
  final height = math.min(dialSize.height, availableHeight);
  final minX = margin;
  final maxX = math.max(minX, bounds.width - margin - width);
  final minY = margin;
  final maxY = math.max(minY, bounds.height - margin - height);

  final centeredX = (selection.center.dx - width / 2).clamp(minX, maxX);
  final centeredY = (selection.center.dy - height / 2).clamp(minY, maxY);

  MenuBarDialPlacement place(double left, double top, MenuBarDialSide side) {
    final rect = Rect.fromLTWH(left, top, width, height);
    return MenuBarDialPlacement(
      rect: rect,
      side: side,
      requested: dialSize,
      overlapsSelection: rect.overlaps(selection),
    );
  }

  final right = selection.right + gap;
  if (right <= maxX) {
    return place(right, centeredY, MenuBarDialSide.right);
  }

  final left = selection.left - gap - width;
  if (left >= minX) {
    return place(left, centeredY, MenuBarDialSide.left);
  }

  final below = selection.bottom + gap;
  if (below <= maxY) {
    return place(centeredX, below, MenuBarDialSide.below);
  }

  final above = selection.top - gap - height;
  if (above >= minY) {
    return place(centeredX, above, MenuBarDialSide.above);
  }

  // 四周都放不下：挑左右剩余空间大的那侧，再夹回边界内。此时浮层会压住选区，
  // 靠 hint 行显示的时间段和「清除」按钮保底。
  final spaceRight = bounds.width - margin - selection.right;
  final spaceLeft = selection.left - margin;
  final x = (spaceRight >= spaceLeft ? right : left).clamp(minX, maxX);
  return place(x, centeredY, MenuBarDialSide.clamped);
}
