import 'package:flutter/widgets.dart';

/// 保活的主页面通过此状态暂停不可见时的昂贵计算。
class MainTabActivity extends InheritedWidget {
  const MainTabActivity({
    super.key,
    required this.isActive,
    required super.child,
  });

  final bool isActive;

  // 页面单独打开时默认可见。
  static bool isActiveOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MainTabActivity>()?.isActive ??
      true;

  @override
  bool updateShouldNotify(MainTabActivity oldWidget) =>
      isActive != oldWidget.isActive;
}
