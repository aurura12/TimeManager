/// Windows/macOS 三列时间网格共享的选中范围。
class DesktopSelection {
  final int? start;
  final int? end;

  const DesktopSelection({this.start, this.end});

  bool appliesTo(DateTime selectionDate, DateTime candidateDate) {
    return selectionDate.year == candidateDate.year &&
        selectionDate.month == candidateDate.month &&
        selectionDate.day == candidateDate.day;
  }

  bool isSingleCellAt(int index) {
    return start != null && end != null && start == index && end == index;
  }
}
