import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/screens/sync_center_screen.dart';
import 'package:time_manager/services/sync_center_service.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/sync_status_button.dart';

Future<SyncCenterController> _controller() async {
  final coordinator = SyncStatusCoordinator(
    store: InMemorySyncStatusStore(),
    loadIdentityBeforeState: false,
  );
  await coordinator.initialize();
  final controller = SyncCenterController(
    operations: SyncCenterOperations(operations: const {}),
    coordinator: coordinator,
  );
  await controller.initialize();
  return controller;
}

Future<void> _pump(
  WidgetTester tester,
  SyncCenterController controller,
  List<SyncModule> modules,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<SyncCenterController>.value(
      value: controller,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          appBar: AppBar(
            actions: [SyncStatusButton(modules: modules, controller: controller)],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('全部正常时不占位', (tester) async {
    final controller = await _controller();
    controller.coordinator.report(
      SyncModule.diary,
      const SyncOperationResult.success(),
    );
    await _pump(tester, controller, const [SyncModule.diary]);

    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('待同步显示黄点图标，点击进入同步中心', (tester) async {
    final controller = await _controller();
    controller.coordinator.report(
      SyncModule.diary,
      const SyncOperationResult.pending('有日记待上传', pendingUploadCount: 1),
    );
    await _pump(tester, controller, const [SyncModule.diary]);

    expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    expect(find.byType(SyncCenterScreen), findsOneWidget);
  });

  testWidgets('失败显示错误图标', (tester) async {
    final controller = await _controller();
    controller.coordinator.report(
      SyncModule.travel,
      const SyncOperationResult.failed('出行同步失败'),
    );
    await _pump(tester, controller, const [SyncModule.travel]);

    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
  });

  testWidgets('同步中显示转圈且不可点击', (tester) async {
    final controller = await _controller();
    controller.coordinator.begin(SyncModule.checkIn, message: '正在同步打卡');
    await _pump(tester, controller, const [SyncModule.checkIn]);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('按本页模块取最严重的状态', (tester) async {
    final controller = await _controller();
    controller.coordinator.report(
      SyncModule.schedule,
      const SyncOperationResult.failed('日程同步失败'),
    );
    controller.coordinator.report(
      SyncModule.diary,
      const SyncOperationResult.success(),
    );
    await _pump(tester, controller, const [SyncModule.diary, SyncModule.schedule]);

    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
  });

  testWidgets('不在本页模块里的异常不显示', (tester) async {
    final controller = await _controller();
    controller.coordinator.report(
      SyncModule.travel,
      const SyncOperationResult.failed('出行同步失败'),
    );
    await _pump(tester, controller, const [SyncModule.diary]);

    expect(find.byType(IconButton), findsNothing);
  });
}
