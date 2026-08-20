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
}
