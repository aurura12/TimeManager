import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/screens/sync_center_screen.dart';
import 'package:time_manager/services/sync_center_service.dart';
import 'package:time_manager/theme/app_theme.dart';

SyncCenterOperations _operationsFor(
  SyncCenterOperation Function(SyncModule module) operation,
) {
  return SyncCenterOperations(
    operations: {
      for (final module in SyncModule.values) module: operation(module),
    },
  );
}

void main() {
  test('全部重试按模块串行执行并保存成功状态', () async {
    final calls = <SyncModule>[];
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async {
          calls.add(module);
          return SyncOperationResult.success(message: '${module.label}完成');
        },
      ),
      store: InMemorySyncCenterStateStore(),
    );
    addTearDown(controller.dispose);

    await controller.retryAll();

    expect(calls, SyncModule.values);
    expect(
      controller.states.every(
        (state) =>
            state.status == SyncModuleStatus.success &&
            state.lastSyncAt != null,
      ),
      isTrue,
    );
  });

  test('失败和冲突状态会保留可理解的信息', () async {
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async {
          if (module == SyncModule.travel) {
            return const SyncOperationResult.conflict(
              '远端出行记录需要确认',
              conflictCount: 2,
              details: ['2026-09-15'],
            );
          }
          return const SyncOperationResult.success();
        },
      ),
      store: InMemorySyncCenterStateStore(),
    );
    addTearDown(controller.dispose);

    await controller.retry(SyncModule.travel);

    final state = controller.stateFor(SyncModule.travel);
    expect(state.status, SyncModuleStatus.conflict);
    expect(state.conflictCount, 2);
    expect(state.failureCount, 1);
    expect(state.message, '远端出行记录需要确认');
    expect(state.details, ['2026-09-15']);
  });

  test('同一模块已有重试时不会重复发起危险并发同步', () async {
    final entered = Completer<void>();
    final result = Completer<SyncOperationResult>();
    var calls = 0;
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () {
          if (module != SyncModule.schedule) {
            return Future<SyncOperationResult>.value(
              const SyncOperationResult.success(),
            );
          }
          calls++;
          if (!entered.isCompleted) entered.complete();
          return result.future;
        },
      ),
      store: InMemorySyncCenterStateStore(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    final first = controller.retry(SyncModule.schedule);
    await entered.future;
    await controller.retry(SyncModule.schedule);

    expect(calls, 1);
    result.complete(const SyncOperationResult.success());
    await first;
  });

  testWidgets('同步中心展示七个模块并支持单模块重试', (tester) async {
    final retried = <SyncModule>[];
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async {
          retried.add(module);
          return const SyncOperationResult.success();
        },
      ),
      store: InMemorySyncCenterStateStore(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SyncCenterScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('同步中心'), findsOneWidget);
    final scheduleRetry = find.byKey(
      const ValueKey('sync-center-retry-schedule'),
    );
    await tester.tap(scheduleRetry);
    await tester.pumpAndSettle();
    expect(retried, [SyncModule.schedule]);
    expect(find.text('已同步'), findsOneWidget);

    for (final module in SyncModule.values) {
      expect(find.text(module.label), findsOneWidget);
    }
    expect(find.text('全部重试'), findsOneWidget);
  });
}
