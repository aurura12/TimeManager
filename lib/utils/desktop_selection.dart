/// Windows/macOS 三列时间网格共享的选中范围。
class DesktopSelection {
  final int? start;
  final int? end;

  const DesktopSelection({this.start, this.end});

  bool appliesTo(DateTime selectionDate, DateTime candidateDate) =>
      isSameDay(selectionDate, candidateDate);

  /// 只比年月日：选区日期可能来自 provider 的 `currentDate`，带时分秒，
  /// 直接用 `DateTime ==` 会把同一天的不同时刻判成两天。
  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool isSingleCellAt(int index) {
    return start != null && end != null && start == index && end == index;
  }
}
