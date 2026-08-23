import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/local_day_range.dart';

void main() {
  test('夏令时切换日范围使用相邻自然日零点', () {
    final range = localDayRange(DateTime(2026, 3, 8, 12));

    expect(range.start, DateTime(2026, 3, 8));
    expect(range.end, DateTime(2026, 3, 9));
  });

  test('冬令时回拨日范围仍覆盖到下一自然日零点', () {
    final range = localDayRange(DateTime(2026, 11, 1, 12));

    expect(range.start, DateTime(2026, 11, 1));
    expect(range.end, DateTime(2026, 11, 2));
  });
}
