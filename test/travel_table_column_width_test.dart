import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/utils/travel_table_columns.dart';

void main() {
  group('TravelColumnLayout.resolve', () {
    test('桌面默认列宽与旧的 flex 2:3 布局等价', () {
      final layout = resolveTravelColumns(
        maxWidth: 1400,
        desktop: true,
        textScale: 1,
      );
      expect(layout.usable, 1400 - 32 - 48 - 8 - 48);
      expect(layout.date, AppSizes.desktopTravelDateColumnWidth);
      final flexWidth = layout.location + layout.event;
      expect(layout.location / flexWidth, closeTo(0.4, 1e-9));
      expect(
        layout.date + layout.location + layout.event,
        closeTo(layout.usable, 1e-9),
      );
    });

    test('手机默认列宽沿用旧值', () {
      final layout = resolveTravelColumns(
        maxWidth: 360,
        desktop: false,
        textScale: 1,
      );
      expect(layout.date, AppSizes.travelDateColumnWidth);
      expect(
        layout.location + layout.event,
        closeTo(layout.usable - layout.date, 1e-9),
      );
    });

    test('两列都拖得很宽时按可让出的余量等比压缩', () {
      final layout = resolveTravelColumns(
        maxWidth: 1400,
        desktop: true,
        textScale: 1,
        dateOverride: 600,
        locationOverride: 600,
      );
      expect(layout.date + layout.location,
          closeTo(layout.usable - layout.minEvent, 1e-9));
      expect(layout.date / layout.location, closeTo(1, 0.02));
      expect(layout.date, greaterThanOrEqualTo(layout.minDate));
      expect(layout.location, greaterThanOrEqualTo(layout.minLocation));
      expect(layout.event, greaterThanOrEqualTo(layout.minEvent - 1e-9));
    });

    test('极窄宽度下三列仍为正且不溢出', () {
      final layout = resolveTravelColumns(
        maxWidth: 300,
        desktop: true,
        textScale: 1,
      );
      expect(layout.date, closeTo(layout.minDate, 1e-9));
      expect(layout.location, closeTo(layout.minLocation, 1e-9));
      expect(layout.event, closeTo(layout.minEvent, 1e-9));
      expect(layout.date, greaterThan(0));
      expect(
        layout.date + layout.location + layout.event,
        closeTo(layout.usable, 1e-9),
      );
    });

    test('大字下默认值随字号放大，用户值只被最小宽度抬起', () {
      final scaled = resolveTravelColumns(
        maxWidth: 1400,
        desktop: true,
        textScale: 1.8,
      );
      expect(scaled.date, closeTo(144 * 1.8, 1e-9));

      final lifted = resolveTravelColumns(
        maxWidth: 1400,
        desktop: true,
        textScale: 1.8,
        dateOverride: 144,
      );
      expect(lifted.date, closeTo(lifted.minDate, 1e-9));
      expect(lifted.date, closeTo(96 * 1.8, 1e-9));
    });
  });

  group('TravelColumnLayout.drag', () {
    TravelColumnLayout base() => resolveTravelColumns(
          maxWidth: 1400,
          desktop: true,
          textScale: 1,
        );

    test('拖日期|地点只改日期，地点让位、事件不变', () {
      final start = base();
      final next = dragTravelColumns(start, divider: 1, dx: 40);
      expect(next.date, closeTo(start.date + 40, 1e-9));
      expect(next.location, closeTo(start.location - 40, 1e-9));
      expect(next.event, closeTo(start.event, 1e-9));
    });

    test('拖地点|事件让事件吸收，日期不动', () {
      final start = base();
      final next = dragTravelColumns(start, divider: 2, dx: 40);
      expect(next.date, closeTo(start.date, 1e-9));
      expect(next.location, closeTo(start.location + 40, 1e-9));
      expect(next.event, closeTo(start.event - 40, 1e-9));
    });

    test('两端都夹在最小宽度里', () {
      final start = base();
      final wide = dragTravelColumns(start, divider: 1, dx: 100000);
      expect(wide.date,
          closeTo(start.usable - start.minLocation - start.event, 1e-9));
      expect(wide.location, closeTo(start.minLocation, 1e-9));

      final narrow = dragTravelColumns(start, divider: 1, dx: -100000);
      expect(narrow.date, closeTo(start.minDate, 1e-9));
      expect(narrow.location,
          closeTo(start.usable - start.minDate - start.event, 1e-9));

      final eventMin = dragTravelColumns(start, divider: 2, dx: 100000);
      expect(eventMin.event, closeTo(start.minEvent, 1e-9));
      final locationMin = dragTravelColumns(start, divider: 2, dx: -100000);
      expect(locationMin.location, closeTo(start.minLocation, 1e-9));
    });

    test('拖动过程中三列总宽保持不变', () {
      final start = base();
      for (final dx in <double>[-500, -33, 0, 17, 90, 400]) {
        for (final divider in <int>[1, 2]) {
          final next = dragTravelColumns(start, divider: divider, dx: dx);
          expect(
            next.date + next.location + next.event,
            closeTo(start.usable, 1e-9),
            reason: 'divider=$divider dx=$dx',
          );
          expect(next.date, greaterThanOrEqualTo(next.minDate - 1e-9));
          expect(next.location, greaterThanOrEqualTo(next.minLocation - 1e-9));
          expect(next.event, greaterThanOrEqualTo(next.minEvent - 1e-9));
        }
      }
    });
  });
}
