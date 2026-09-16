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
  test('刷新同步中心会执行配置的实时检查', () async {
    var checks = 0;
    final controller = SyncCenterController(
      operations: SyncCenterOperations(
        operations: {
          for (final module in SyncModule.values)
            module: () async => const SyncOperationResult.success(),
        },
        checks: {
          SyncModule.schedule: () async {
            checks++;
            return const SyncOperationResult.success(
              message: '已确认本地与远端日程一致',
            );
          },
        },
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(controller.dispose);

    await controller.refresh();
    expect(checks, 1);
    expect(
      controller.stateFor(SyncModule.schedule).status,
      SyncModuleStatus.success,
    );

    await controller.refresh();
    expect(checks, 2);
  });

  test('初始化前不让默认 live 状态覆盖持久待同步，状态就绪后再刷新', () async {
    final ready = Completer<void>();
    final liveSource = ValueNotifier<int>(0);
    var livePending = 2;
    var liveReads = 0;
    final scheduleKey = SyncStatusCoordinator.defaultContextKeyFor(
      SyncModule.schedule,
    );
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async => const SyncOperationResult.success(),
      ),
      store: InMemorySyncStatusStore({
        scheduleKey: const SyncModuleState(
          module: SyncModule.schedule,
          status: SyncModuleStatus.pending,
          pendingUploadCount: 2,
        ),
      }),
      loadIdentityBeforeState: false,
      waitForLiveState: () => ready.future,
      liveStateSource: liveSource,
      liveStateReader: () {
        liveReads++;
        return {
          SyncModule.schedule: SyncModuleState(
            module: SyncModule.schedule,
            status: livePending > 0
                ? SyncModuleStatus.pending
                : SyncModuleStatus.idle,
            pendingUploadCount: livePending,
          ),
        };
      },
      authoritativeLiveStateModules: const {SyncModule.schedule},
    );
    addTearDown(() {
      liveSource.dispose();
      controller.dispose();
    });

    final initialization = controller.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(controller.isInitialized, isFalse);
    expect(controller.stateFor(SyncModule.schedule).pendingUploadCount, 2);
    expect(liveReads, 0);

    ready.complete();
    await initialization;
    expect(liveReads, greaterThan(0));
    expect(controller.stateFor(SyncModule.schedule).pendingUploadCount, 2);

    livePending = 0;
    liveSource.value++;
    await Future<void>.delayed(Duration.zero);
    expect(controller.stateFor(SyncModule.schedule).pendingUploadCount, 0);
  });

  test('全部重试按模块串行执行并保存成功状态', () async {
    final calls = <SyncModule>[];
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async {
          calls.add(module);
          return SyncOperationResult.success(message: '${module.label}完成');
        },
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(controller.dispose);

    await controller.retryAll();

    expect(calls, SyncModule.values);
    expect(
      controller.states.every(
        (state) =>
            state.status == SyncModuleStatus.success &&
            state.lastSuccessAt != null,
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
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
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

  test('未执行或仍有待同步项时，控制器仍标记为未完成', () async {
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async => module == SyncModule.travel
            ? const SyncOperationResult.skipped('远程视图下不推送')
            : module == SyncModule.checkIn
                ? const SyncOperationResult.success(
                    message: '照片待重试',
                    pendingUploadCount: 1,
                  )
                : const SyncOperationResult.success(),
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(controller.dispose);

    await controller.retryAll();

    expect(controller.hasUnresolved, isTrue);
    expect(controller.stateFor(SyncModule.travel).status,
        SyncModuleStatus.skipped);
    expect(controller.stateFor(SyncModule.checkIn).hasPending, isTrue);
  });

  test('只有未执行状态时不提示仍有模块待处理', () async {
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async => module == SyncModule.travel
            ? const SyncOperationResult.skipped('远程视图下不推送')
            : const SyncOperationResult.success(),
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(controller.dispose);

    await controller.retryAll();

    expect(controller.stateFor(SyncModule.travel).status,
        SyncModuleStatus.skipped);
    expect(controller.hasUnresolved, isFalse);
  });

  test('没有可靠打卡 live reader 时保留远端照片部分失败的待上传数', () async {
    var liveReads = 0;
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async {
          if (module == SyncModule.checkIn) {
            return const SyncOperationResult.success(
              message: '打卡数据已同步，部分照片待重试',
              pendingUploadCount: 1,
              pendingDownloadCount: 2,
            );
          }
          return const SyncOperationResult.success();
        },
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
      liveStateReader: () {
        liveReads++;
        return {
          for (final module in SyncModule.values)
            module: SyncModuleState(module: module),
        };
      },
      // 只有日程的 Provider 状态能可靠提供实时计数；打卡照片没有
      // live reader，默认的 0 不能覆盖 push 结果。
      authoritativeLiveStateModules: const {SyncModule.schedule},
    );
    addTearDown(controller.dispose);

    await controller.retry(SyncModule.checkIn);

    final state = controller.stateFor(SyncModule.checkIn);
    expect(liveReads, greaterThan(0));
    expect(state.status, SyncModuleStatus.pending);
    expect(state.pendingUploadCount, 1);
    expect(state.pendingDownloadCount, 2);
    expect(state.failureCount, 0);
    expect(state.conflictCount, 0);
  });

  test('busy 任务在 live reader 回落后可再次重试并恢复为已同步', () async {
    var calls = 0;
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async {
          if (module == SyncModule.schedule && calls++ == 0) {
            return const SyncOperationResult.busy('已有同步任务正在进行，请稍后再试');
          }
          return const SyncOperationResult.success(message: '日程同步完成');
        },
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
      liveStateReader: () => {
        SyncModule.schedule: const SyncModuleState(
          module: SyncModule.schedule,
          status: SyncModuleStatus.idle,
        ),
      },
      authoritativeLiveStateModules: const {SyncModule.schedule},
    );
    addTearDown(controller.dispose);

    await controller.retry(SyncModule.schedule);
    expect(
        controller.stateFor(SyncModule.schedule).status, SyncModuleStatus.idle);
    expect(
      controller.stateFor(SyncModule.schedule).message,
      '同步任务已结束，可重试',
    );
    expect(controller.isRetrying, isFalse);

    await controller.retry(SyncModule.schedule);
    expect(calls, 2);
    expect(
      controller.stateFor(SyncModule.schedule).status,
      SyncModuleStatus.success,
    );
    expect(controller.isRetrying, isFalse);
  });

  test('live reader 不会把业务失败和冲突结果改回同步中', () async {
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async {
          if (module == SyncModule.travel) {
            return const SyncOperationResult.conflict(
              '远端出行记录需要确认',
              conflictCount: 2,
            );
          }
          return const SyncOperationResult.success();
        },
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
      liveStateReader: () => {
        SyncModule.travel: const SyncModuleState(
          module: SyncModule.travel,
          status: SyncModuleStatus.syncing,
        ),
      },
      authoritativeLiveStateModules: const {SyncModule.travel},
    );
    addTearDown(controller.dispose);

    await controller.retry(SyncModule.travel);
    await controller.refresh();

    final state = controller.stateFor(SyncModule.travel);
    expect(state.status, SyncModuleStatus.conflict);
    expect(state.failureCount, 1);
    expect(state.conflictCount, 2);
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
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
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

  test('操作结果中的待同步数量不会被不完整的 live reader 清零', () async {
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async => module == SyncModule.checkIn
            ? const SyncOperationResult.success(
                message: '照片部分失败',
                pendingUploadCount: 1,
              )
            : const SyncOperationResult.success(),
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
      // 生产 Provider 只对日程/Google 日历提供 live 状态；其它模块不应
      // 用默认的 0 覆盖本次操作返回的 pending 数量。
      liveStateReader: () => {
        SyncModule.schedule: const SyncModuleState(
          module: SyncModule.schedule,
        ),
        SyncModule.googleCalendar: const SyncModuleState(
          module: SyncModule.googleCalendar,
        ),
      },
    );
    addTearDown(controller.dispose);

    await controller.retry(SyncModule.checkIn);

    final state = controller.stateFor(SyncModule.checkIn);
    expect(state.status, SyncModuleStatus.pending);
    expect(state.pendingUploadCount, 1);
  });

  test('busy 操作结束后不会把模块永久卡在已有任务进行中', () async {
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async => module == SyncModule.travel
            ? const SyncOperationResult.busy('已有出行同步任务')
            : const SyncOperationResult.success(),
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(controller.dispose);

    await controller.retry(SyncModule.travel);

    final state = controller.stateFor(SyncModule.travel);
    expect(state.status, SyncModuleStatus.idle);
    expect(state.message, '已有出行同步任务');
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
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
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

  testWidgets('首次安装时同步中心显示「尚未检查」而不是「未同步」', (tester) async {
    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async => const SyncOperationResult.success(),
      ),
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SyncCenterScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('尚未检查'), findsNWidgets(SyncModule.values.length));
    expect(find.text('未同步'), findsNothing);
    expect(find.text('最后成功：暂无记录'), findsNWidgets(SyncModule.values.length));
  });

  testWidgets('日程页等外部入口同步成功后，打开同步中心立即显示已同步', (tester) async {
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
      scopeResolver: (_) => 'g',
    );
    addTearDown(coordinator.dispose);

    // 模拟日程页/后台自动同步直接上报结果，整个过程没有经过同步中心。
    coordinator.report(
      SyncModule.schedule,
      const SyncOperationResult.success(message: '日程同步完成'),
      source: '日程页',
    );
    expect(
      coordinator.stateFor(SyncModule.schedule).status,
      SyncModuleStatus.success,
    );

    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async => const SyncOperationResult.success(),
      ),
      coordinator: coordinator,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SyncCenterScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final scheduleState = controller.stateFor(SyncModule.schedule);
    expect(scheduleState.status, SyncModuleStatus.success);
    expect(scheduleState.lastSuccessAt, isNotNull);
    expect(find.text('已同步'), findsOneWidget);
    expect(find.text('日程同步完成'), findsOneWidget);
    expect(
      find.text('最后成功：暂无记录'),
      findsNWidgets(SyncModule.values.length - 1),
    );
  });

  test('刷新页面状态不会把已同步重置为尚未检查', () async {
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
      scopeResolver: (_) => 'g',
    );
    addTearDown(coordinator.dispose);

    final controller = SyncCenterController(
      operations: _operationsFor(
        (module) => () async => const SyncOperationResult.success(),
      ),
      coordinator: coordinator,
      liveStateReader: () => {
        SyncModule.schedule: const SyncModuleState(
          module: SyncModule.schedule,
          status: SyncModuleStatus.idle,
        ),
      },
      authoritativeLiveStateModules: const {SyncModule.schedule},
    );
    addTearDown(controller.dispose);

    await controller.retry(SyncModule.schedule);
    final successAt = controller.stateFor(SyncModule.schedule).lastSuccessAt;
    expect(successAt, isNotNull);

    await controller.refresh();

    final refreshed = controller.stateFor(SyncModule.schedule);
    expect(refreshed.status, SyncModuleStatus.success);
    expect(refreshed.lastSuccessAt, successAt);
  });
}
