import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/time_provider.dart';
import '../screens/home_screen.dart';
import '../screens/global_search_screen.dart';
import '../screens/sync_center_screen.dart';
import '../theme/app_tokens.dart';
import 'home_widget_service.dart';

/// 处理 Android 小组件发出的动作，并把它们映射到已有页面。
///
/// 这里不直接改 MainScreen 的 Tab 状态：小组件点击会进入一个明确的
/// 页面路由，返回时仍回到启动前的页面，避免动作被静默吞掉或落到首页。
class HomeWidgetActionRouter {
  HomeWidgetActionRouter._();

  static Future<void> dispatch({
    required BuildContext context,
    required NavigatorState navigator,
    required HomeWidgetActionRequest request,
  }) {
    switch (request.action) {
      case HomeWidgetAction.todayRecords:
        // HomeScreen 默认显示当前日期；这里显式回到今天，处理用户之前
        // 正在查看其他日期的场景。
        context.read<TimeProvider>().goToDate(DateTime.now());
        _report('已打开今日记录');
        return navigator.push<void>(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: request.routeName),
            builder: (_) => const HomeScreen(),
          ),
        );
      case HomeWidgetAction.search:
        _report('已打开搜索');
        return navigator.push<void>(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: request.routeName),
            builder: (_) => const GlobalSearchScreen(),
          ),
        );
      case HomeWidgetAction.syncCenter:
        _report('已打开同步中心');
        return navigator.push<void>(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: request.routeName),
            builder: (_) => const SyncCenterScreen(),
          ),
        );
      case HomeWidgetAction.invalid:
        _report('小组件操作无效，请重新点击', isError: true);
        return navigator.push<void>(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: request.routeName),
            builder: (_) => const _InvalidHomeWidgetActionScreen(),
          ),
        );
    }
  }

  static void _report(String message, {bool isError = false}) {
    unawaited(_reportSafely(message, isError: isError));
  }

  static Future<void> _reportSafely(
    String message, {
    required bool isError,
  }) async {
    try {
      await HomeWidgetService.reportActionStatus(
        message,
        isError: isError,
      );
    } catch (error) {
      // 路由已经完成时，小组件状态写回失败不应阻断用户进入页面。
      debugPrint('写入小组件动作状态失败: $error');
    }
  }
}

class _InvalidHomeWidgetActionScreen extends StatelessWidget {
  const _InvalidHomeWidgetActionScreen();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('小组件操作')),
      body: Center(
        child: Padding(
          padding: AppSpacing.page,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                '无法识别这个小组件操作',
                style: textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '请返回后重新点击小组件中的快捷入口。',
                style: textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回应用'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
