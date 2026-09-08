import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/screens/app_log_screen.dart';
import 'package:time_manager/services/app_log_service.dart';

import 'support/fake_app_log_store.dart';

void main() {
  AppLogService createService() {
    return AppLogService(
      store: FakeAppLogStore(),
      clock: () => DateTime.utc(2026, 9, 8, 12, 34, 56, 789),
    );
  }

  testWidgets('运行日志页支持查看、筛选和查看详情', (tester) async {
    final service = createService();
    await service.initialize();
    service.info('应用启动完成', source: 'startup');
    service.error(
      '同步失败',
      source: 'sync',
      error: 'network failure',
      stackTrace: StackTrace.fromString('stack line 1'),
    );

    await tester.pumpWidget(
      MaterialApp(home: AppLogScreen(service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text('运行日志'), findsOneWidget);
    expect(find.byTooltip('导出日志'), findsOneWidget);
    expect(find.byTooltip('复制全部'), findsOneWidget);
    expect(find.byTooltip('清空日志'), findsOneWidget);
    expect(find.text('应用启动完成'), findsOneWidget);
    expect(find.text('同步失败'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('log-filter-error')));
    await tester.pumpAndSettle();
    expect(find.text('应用启动完成'), findsNothing);
    expect(find.text('同步失败'), findsOneWidget);

    await tester.tap(find.text('同步失败'));
    await tester.pumpAndSettle();
    expect(find.text('日志详情'), findsOneWidget);
    expect(find.text('异常：'), findsOneWidget);
    expect(find.text('network failure'), findsOneWidget);
    expect(find.text('stack line 1'), findsOneWidget);
  });

  testWidgets('运行日志页可以清空全部日志', (tester) async {
    final service = createService();
    await service.initialize();
    service.warning('需要清理的日志', source: 'test');

    await tester.pumpWidget(
      MaterialApp(home: AppLogScreen(service: service)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('清空日志'));
    await tester.pumpAndSettle();
    expect(find.text('清空运行日志？'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('log-clear-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('需要清理的日志'), findsNothing);
    expect(service.entries, isEmpty);
  });
}
