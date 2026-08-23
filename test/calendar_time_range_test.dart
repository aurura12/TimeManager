import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/calendar_time_range.dart';

void main() {
  test('结束于次日零点的事件占用当天最后六个时间槽', () {
    final day = DateTime(2026, 8, 24);

    final indices = calendarTimeRangeToSlotIndices(
      DateTime(2026, 8, 24, 23),
      DateTime(2026, 8, 25),
      day,
    );

    expect(indices, [138, 139, 140, 141, 142, 143]);
  });

  test('跨越整天的事件裁剪为当天全部时间槽', () {
    final day = DateTime(2026, 8, 24);

    final indices = calendarTimeRangeToSlotIndices(
      DateTime(2026, 8, 23, 22),
      DateTime(2026, 8, 25, 1),
      day,
    );

    expect(indices, List<int>.generate(144, (index) => index));
  });

  test('夏令时切换日的全天事件仍占用全部时间槽', () {
    final day = DateTime(2026, 3, 8);

    final indices = calendarTimeRangeToSlotIndices(
      DateTime(2026, 3, 8),
      DateTime(2026, 3, 9),
      day,
    );

    expect(indices, List<int>.generate(144, (index) => index));
  });

  test('普通整点结束时间保持右开区间', () {
    final day = DateTime(2026, 8, 24);

    final indices = calendarTimeRangeToSlotIndices(
      DateTime(2026, 8, 24, 9),
      DateTime(2026, 8, 24, 10),
      day,
    );

    expect(indices, [54, 55, 56, 57, 58, 59]);
  });
}
