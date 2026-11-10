import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/menu_bar_provider.dart';
import 'menu_bar_panel.dart';

/// 应用根壳：主界面与菜单栏面板共用一个 Flutter engine。
///
/// 面板显示时主窗口只有 400×560，如果让 MainScreen 按这个宽度布局会触发
/// overflow 并刷错误日志。这里用 [Offstage] 跳过绘制、用 [OverflowBox]
/// 固定一个桌面尺寸，同时保持 widget 层级不变，避免 MainScreen 被重建
/// （它的 Tab 状态、滚动位置与「那年今日」会话标记都要留着）。
class AppRootShell extends StatelessWidget {
  const AppRootShell({
    super.key,
    required this.child,
    this.onOpenRecordAtDate,
  });

  final Widget child;

  /// 面板里「在主窗口中查看」用：定位到指定日期。
  final ValueChanged<DateTime>? onOpenRecordAtDate;

  /// 离屏时主界面按这个尺寸布局：必须大于面板，且是桌面布局的常规宽度。
  static const Size detachedLayoutSize = Size(1200, 800);

  @override
  Widget build(BuildContext context) {
    final menuBar = context.watch<MenuBarProvider?>();
    final mainVisible = menuBar?.mainWindowVisible ?? true;
    final panelVisible = menuBar?.panelVisible ?? false;
    final media = MediaQuery.of(context);
    final layoutSize = mainVisible ? media.size : detachedLayoutSize;

    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: !mainVisible,
          child: ExcludeFocus(
            excluding: !mainVisible,
            child: TickerMode(
              enabled: mainVisible,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: layoutSize.width,
                maxWidth: layoutSize.width,
                minHeight: layoutSize.height,
                maxHeight: layoutSize.height,
                child: MediaQuery(
                  data: media.copyWith(size: layoutSize),
                  child: child,
                ),
              ),
            ),
          ),
        ),
        if (panelVisible)
          Positioned.fill(
            child: MenuBarPanel(onOpenRecordAtDate: onOpenRecordAtDate),
          ),
      ],
    );
  }
}
