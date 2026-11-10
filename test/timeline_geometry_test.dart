import 'dart:ui' show Rect;

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

  group('timelineSelectionRect', () {
    Rect rect(
      int start,
      int end, {
      double offset = 0,
      double width = 368,
      double inset = 0,
    }) =>
        timelineSelectionRect(
          startIndex: start,
          endIndex: end,
          contentWidth: width,
          gridLeft: 55,
          scrollOffset: offset,
          rowExtent: 45,
          topPadding: 8,
          cellInset: inset,
        );

    test('单格取所在行与列的边界', () {
      final r = rect(54, 54);
      expect(r.left, closeTo(55, 1e-9));
      expect(r.right, closeTo(55 + (368 - 55) / 6, 1e-9));
      expect(r.top, closeTo(8 + 9 * 45, 1e-9));
      expect(r.bottom, closeTo(8 + 10 * 45, 1e-9));
    });

    test('同行多格横向连成一段', () {
      final r = rect(54, 56);
      expect(r.left, closeTo(55, 1e-9));
      expect(r.right, closeTo(55 + 3 * (368 - 55) / 6, 1e-9));
    });

    test('跨行时横向铺满整行', () {
      final r = rect(4, 7);
      expect(r.left, 55);
      expect(r.right, 368);
      expect(r.top, closeTo(8, 1e-9));
      expect(r.bottom, closeTo(8 + 2 * 45, 1e-9));
    });

    test('起止反着选也按同一矩形算', () {
      expect(rect(56, 54), rect(54, 56));
    });

    test('减去纵向滚动偏移', () {
      final scrolled = rect(54, 55, offset: 300);
      expect(scrolled.top, closeTo(rect(54, 55).top - 300, 1e-9));
      expect(scrolled.bottom, closeTo(rect(54, 55).bottom - 300, 1e-9));
    });

    test('单元格内缩把相邻格子之间的缝留出来', () {
      final r = rect(54, 54, inset: 1);
      expect(r.left, closeTo(56, 1e-9));
      expect(r.top, closeTo(8 + 9 * 45 + 1, 1e-9));
      expect(r.height, closeTo(43, 1e-9));
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
