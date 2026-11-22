import 'dart:math' as math;

import '../theme/app_tokens.dart';

/// 出行表格三列在某一可用宽度下解析出的显示宽度。
///
/// 事件列在布局里仍由 `Expanded` 取余数，[event] 只服务拖拽数学：
/// 拖动期间 [date] + [location] + [event] 恒等于 [usable]，所以不会触发压缩、
/// 松手也不会跳一下。
class TravelColumnLayout {
  const TravelColumnLayout({
    required this.date,
    required this.location,
    required this.event,
    required this.usable,
    required this.minDate,
    required this.minLocation,
    required this.minEvent,
  });

  final double date;
  final double location;
  final double event;

  /// 日期 + 地点 + 事件三列的总可用宽度。
  final double usable;

  final double minDate;
  final double minLocation;
  final double minEvent;

  TravelColumnLayout _copyWith({
    double? date,
    double? location,
    double? event,
  }) {
    return TravelColumnLayout(
      date: date ?? this.date,
      location: location ?? this.location,
      event: event ?? this.event,
      usable: usable,
      minDate: minDate,
      minLocation: minLocation,
      minEvent: minEvent,
    );
  }
}

/// 列间距，同时也是拖拽分隔条的宽度。
double travelColumnGap({required bool desktop}) =>
    desktop ? AppSpacing.xl : AppSpacing.sm;

/// 行内左右内边距，与表头和每一行共用。
double travelColumnHorizontalPadding({required bool desktop}) =>
    desktop ? AppSpacing.lg : AppSpacing.xs;

/// 解析三列当前应该显示的宽度。
///
/// [dateOverride] / [locationOverride] 是用户拖出来的像素值（null = 默认宽度）；
/// 字号的放大通过最小宽度体现，只影响显示、不改用户值。
TravelColumnLayout resolveTravelColumns({
  required double maxWidth,
  required bool desktop,
  required double textScale,
  double? dateOverride,
  double? locationOverride,
}) {
  final scale = textScale.isFinite && textScale > 0 ? textScale : 1.0;
  final gap = travelColumnGap(desktop: desktop);
  final horizontalPadding = travelColumnHorizontalPadding(desktop: desktop);
  final usable = math.max(
    0.0,
    maxWidth -
        horizontalPadding * 2 -
        gap * 2 -
        AppSpacing.sm -
        AppSizes.minTapTarget,
  );

  // 最小宽度随字号放大，但带比例上限，保证三列都拿得到正宽度：
  // 30% + 30% 恰好是 1 - 40%，所以 roomForTwo 减去两列最小宽度不会为负。
  final minDate = math.min(
    AppSizes.travelDateColumnMinWidth * scale,
    usable * 0.3,
  );
  final minLocation = math.min(
    AppSizes.travelLocationColumnMinWidth * scale,
    usable * 0.3,
  );
  final minEvent = math.min(
    AppSizes.travelEventColumnMinWidth * scale,
    usable * 0.4,
  );
  final roomForTwo = math.max(0.0, usable - minEvent);

  final defaultDate =
      (desktop
          ? AppSizes.desktopTravelDateColumnWidth
          : AppSizes.travelDateColumnWidth) *
      scale;
  final flexTotal = AppSizes.travelLocationFlex + AppSizes.travelEventFlex;
  final defaultLocation =
      math.max(0.0, usable - defaultDate) *
      (AppSizes.travelLocationFlex / flexTotal);

  var date = dateOverride ?? defaultDate;
  var location = locationOverride ?? defaultLocation;

  // 两列都偏宽时按「各自还能让出多少」等比压缩，避免先到先得把一列压到最小。
  final wanted = date + location;
  if (wanted > roomForTwo) {
    final dateSlack = math.max(0.0, date - minDate);
    final locationSlack = math.max(0.0, location - minLocation);
    final slack = dateSlack + locationSlack;
    if (slack > 0) {
      final ratio = math.min(1.0, (wanted - roomForTwo) / slack);
      date -= dateSlack * ratio;
      location -= locationSlack * ratio;
    }
  }

  date = date
      .clamp(minDate, math.max(minDate, roomForTwo - minLocation))
      .toDouble();
  location = location
      .clamp(minLocation, math.max(minLocation, roomForTwo - date))
      .toDouble();

  return TravelColumnLayout(
    date: date,
    location: location,
    event: usable - date - location,
    usable: usable,
    minDate: minDate,
    minLocation: minLocation,
    minEvent: minEvent,
  );
}

/// 把分隔条 [divider]（1 = 日期|地点，2 = 地点|事件）拖动累计 [dx] 像素后的结果。
///
/// 1 号分隔条改日期列、地点让位、事件不变；2 号改地点列、事件吸收。
/// 两端都夹在最小宽度内，所以拖动过程中不会触发压缩。
TravelColumnLayout dragTravelColumns(
  TravelColumnLayout current, {
  required int divider,
  required double dx,
}) {
  if (divider == 1) {
    final maxDate = math.max(
      current.minDate,
      current.usable - current.minLocation - current.event,
    );
    final date = (current.date + dx).clamp(current.minDate, maxDate).toDouble();
    return current._copyWith(
      date: date,
      location: current.usable - date - current.event,
    );
  }

  final maxLocation = math.max(
    current.minLocation,
    current.usable - current.date - current.minEvent,
  );
  final location = (current.location + dx)
      .clamp(current.minLocation, maxLocation)
      .toDouble();
  return current._copyWith(
    location: location,
    event: current.usable - current.date - location,
  );
}
