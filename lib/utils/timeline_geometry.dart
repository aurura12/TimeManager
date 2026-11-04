/// 时间网格的几何换算。
///
/// 记录页的时间轴、手机单列网格与桌面三列网格共用同一套行高与内边距，
/// 以前这些数字（45 / 8）散落在命中测试与初始滚动里，改行高就会一起错位。
library;

/// 一天中的分钟数（0..1440）。
int minutesOfDayOf(DateTime time) => time.hour * 60 + time.minute;

/// 一小时的格子数：每格 10 分钟。
const int slotsPerHour = 6;

/// 分钟（0..59）在所属小时行内的 x（内容坐标）。
///
/// 网格每小时占一整行宽、横向 6 格共 60 分钟，所以分钟按比例铺到行宽上，
/// 10 分钟刻度天然对齐格子边界。
double timelineXForMinute(int minuteOfHour, {required double rowWidth}) {
  return rowWidth * minuteOfHour.clamp(0, 59) / 60.0;
}

/// 分钟 → 时间轴内容坐标里的 y（含列表顶部的内边距）。
double timelineYForMinutes(
  int minutesOfDay, {
  required double rowExtent,
  required double topPadding,
}) {
  final clamped = minutesOfDay.clamp(0, 24 * 60);
  return topPadding + clamped * rowExtent / 60.0;
}

/// 内容坐标 y → 小时行号（0..rowCount-1）。
int timelineRowAt(
  double contentY, {
  required double rowExtent,
  required double topPadding,
  int rowCount = 24,
}) {
  final row = ((contentY - topPadding) / rowExtent).floor();
  return row.clamp(0, rowCount - 1);
}

/// 「滚到现在」的目标偏移：让当前时刻落在大约 [leadFraction] 视口处。
double timelineScrollOffsetForNow({
  required int minutesOfDay,
  required double rowExtent,
  required double topPadding,
  required double viewportExtent,
  required double maxScrollExtent,
  double leadFraction = 1 / 3,
}) {
  final y = timelineYForMinutes(
    minutesOfDay,
    rowExtent: rowExtent,
    topPadding: topPadding,
  );
  final raw = y - viewportExtent * leadFraction;
  final max = maxScrollExtent.isNegative ? 0.0 : maxScrollExtent;
  return raw.clamp(0.0, max);
}
