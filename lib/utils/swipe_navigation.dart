/// 左右滑动切日的手势判定。
///
/// 单独抽成纯函数，是为了让阈值与「横竖哪个占优」的规则可测，
/// 页面只负责收集指针位移并按结果切日。
library;

enum SwipeNavigationDirection { previous, next }

/// 根据累计位移与速度判定是否构成「切换上一天 / 下一天」。
///
/// - 位移达到 [minDistance] 且横向位移大于纵向位移才算滑动；
/// - 位移不足时允许用速度兜底（快速轻扫）；
/// - 返回 null 表示这次手势不该切日（可能是滚动、竖向拖动或点按）。
SwipeNavigationDirection? resolveSwipeNavigation({
  required double dx,
  required double dy,
  required double velocityX,
  double minDistance = 48,
  double minVelocity = 300,
}) {
  final byDistance = dx.abs() >= minDistance;
  final byVelocity = velocityX.abs() >= minVelocity;
  if (!byDistance && !byVelocity) return null;
  if (byDistance && dx.abs() <= dy.abs()) return null;

  final leftward = byDistance ? dx < 0 : velocityX < 0;
  return leftward
      ? SwipeNavigationDirection.next
      : SwipeNavigationDirection.previous;
}
