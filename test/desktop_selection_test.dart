import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/desktop_selection.dart';

void main() {
  test('selection belongs to one date and can clear its single cell', () {
    final date = DateTime(2026, 8, 20);
    const selection = DesktopSelection(
      start: 12,
      end: 12,
    );

    expect(selection.appliesTo(date, date), isTrue);
    expect(
        selection.appliesTo(date, date.add(const Duration(days: 1))), isFalse);
    expect(selection.isSingleCellAt(12), isTrue);
    expect(selection.isSingleCellAt(13), isFalse);
  });

  test('sameday comparison ignores time of day', () {
    final morning = DateTime(2026, 8, 20, 7, 30, 15);
    final night = DateTime(2026, 8, 20, 23, 59);

    expect(DesktopSelection.isSameDay(morning, night), isTrue);
    expect(DesktopSelection.isSameDay(morning, DateTime(2026, 8, 21, 7, 30)),
        isFalse);
    expect(DesktopSelection.isSameDay(DateTime(2025, 8, 20, 7, 30), morning),
        isFalse);

    // appliesTo 复用同一判定：选区日期带时分秒也不该串到别的列
    const selection = DesktopSelection(start: 1, end: 2);
    expect(selection.appliesTo(night, morning), isTrue);
    expect(selection.appliesTo(night, DateTime(2026, 8, 21)), isFalse);
  });
}
