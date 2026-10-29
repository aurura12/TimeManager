import 'package:flutter/material.dart';

/// 桌面端统一挂「常显」滚动条。
///
/// Flutter 默认只在滚动时淡入一条很细的滚动条，桌面端长列表几乎看不见。
/// 这里只改桌面平台：移动端保持原样（系统本来就不常显滚动条）。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (axisDirectionToAxis(details.direction) == Axis.horizontal) {
      return child;
    }
    switch (getPlatform(context)) {
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        final controller = details.controller;
        // thumbVisibility 要求有 ScrollController；拿不到就退回默认行为，
        // 避免 "A ScrollController is required when Scrollbar.thumbVisibility
        // is true" 断言。
        if (controller == null) return child;
        return Scrollbar(
          controller: controller,
          thumbVisibility: true,
          child: child,
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return child;
    }
  }
}
