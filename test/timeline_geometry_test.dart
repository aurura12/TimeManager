import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/timeline_geometry.dart';

void main() {
  group('minutesOfDayOf', () {
    test('按本地时间换算成当天分钟', () {
      expect(minutesOfDayOf(DateTime(2026, 10, 29, 0, 0)), 0);
      expect(minutesOfDayOf(DateTime(2026, 10, 29, 7, 30)), 450);
      expect(minutesOfDayOf(DateTime(2026, 10, 29, 23, 59)), 1439);
    });
  });

  group('timelineYForMinutes', () {
    double y(int minutes) =>
        timelineYForMinutes(minutes, rowExtent: 45, topPadding: 8);

    test('包含顶部内边距', () {
      expect(y(0), 8);
      expect(y(60), closeTo(53, 1e-9));
      expect(y(14 * 60 + 30), closeTo(8 + 14.5 * 45, 1e-9));
    });

    test('越界分钟夹到一天之内', () {
      expect(y(-30), y(0));
      expect(y(24 * 60 + 60), y(24 * 60));
    });
  });

  group('timelineRowAt', () {
    int row(double contentY) =>
        timelineRowAt(contentY, rowExtent: 45, topPadding: 8);

    test('按行高换算并夹到 0..23', () {
      expect(row(0), 0);
      expect(row(8), 0);
      expect(row(52.9), 0);
      expect(row(53), 1);
      expect(row(8 + 45 * 10.5), 10);
      expect(row(-100), 0);
      expect(row(99999), 23);
    });
  });

  group('timelineScrollOffsetForNow', () {
    double offset(int minutes, {double viewport = 600, double max = 10000}) =>
        timelineScrollOffsetForNow(
          minutesOfDay: minutes,
          rowExtent: 45,
          topPadding: 8,
          viewportExtent: viewport,
          maxScrollExtent: max,
        );

    test('把当前时刻放到视口上 1/3', () {
      expect(offset(12 * 60), closeTo(8 + 12 * 45 - 200, 1e-9));
    });

    test('凌晨夹到 0，深夜夹到最大偏移', () {
      expect(offset(0), 0);
      expect(offset(23 * 60 + 59, viewport: 600, max: 500), 500);
    });

    test('内容不足一屏时最大偏移为负也不越界', () {
      expect(offset(12 * 60, viewport: 600, max: -20), 0);
    });
  });
}
