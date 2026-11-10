import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/menu_bar_provider.dart';
import '../utils/app_snack_bar.dart';

/// 「设置 → 操作与布局」里的菜单栏常驻开关。
///
/// 没有注册 [MenuBarProvider]（老测试宿主）或非 macOS 时不渲染任何内容。
class MenuBarSettingsTiles extends StatelessWidget {
  const MenuBarSettingsTiles({super.key});

  @override
  Widget build(BuildContext context) {
    final menuBar = context.watch<MenuBarProvider?>();
    if (menuBar == null || !menuBar.supported) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.vertical_align_top_outlined),
          title: const Text('菜单栏常驻'),
          subtitle: Text(
            menuBar.enabled
                ? '启动后只显示菜单栏图标，点图标查看今日速览'
                : '关闭后恢复普通窗口模式，关窗即退出',
          ),
          value: menuBar.enabled,
          onChanged: (value) async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            try {
              await menuBar.setEnabled(value);
            } on Object {
              showAppSnackBarOn(messenger, '切换菜单栏模式失败，已恢复原设置');
            }
          },
        ),
        if (menuBar.launchAtLoginAvailable)
          SwitchListTile(
            secondary: const Icon(Icons.login_outlined),
            title: const Text('登录时自动启动'),
            subtitle: Text(
              menuBar.launchAtLoginNeedsApproval
                  ? '已被系统关闭，请在「系统设置 → 通用 → 登录项」中允许'
                  : '登录后自动在菜单栏待命',
            ),
            value: menuBar.launchAtLogin,
            onChanged: (value) async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              try {
                await menuBar.setLaunchAtLogin(value);
              } on Object catch (error) {
                showAppSnackBarOn(
                  messenger,
                  '设置登录项失败：${menuBar.describeLaunchAtLoginError(error)}',
                );
              }
            },
          ),
      ],
    );
  }
}
