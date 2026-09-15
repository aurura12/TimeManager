import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/services/sync_status_coordinator.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('首次安装的模块显示为尚未检查，而不是未同步', () {
    expect(SyncModuleStatus.idle.label, '尚未检查');

    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      scopeResolver: (_) => 'g',
    );
    addTearDown(coordinator.dispose);

    final state = coordinator.stateFor(SyncModule.schedule);
    expect(state.status, SyncModuleStatus.idle);
    expect(state.lastSuccessAt, isNull);
    expect(state.message, isNull);
  });

  test('成功的同步会记录成功时间并清除待上传', () async {
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      scopeResolver: (_) => 'g',
    );
    addTearDown(coordinator.dispose);

    coordinator.markPending(
      SyncModule.schedule,
      uploadCount: 2,
      message: '有日程修改待上传',
    );
    expect(coordinator.stateFor(SyncModule.schedule).status,
        SyncModuleStatus.pending);
    expect(coordinator.stateFor(SyncModule.schedule).pendingUploadCount, 2);

    coordinator.report(
      SyncModule.schedule,
      const SyncOperationResult.success(message: '日程同步完成'),
      source: '日程页',
    );

    final state = coordinator.stateFor(SyncModule.schedule);
    expect(state.status, SyncModuleStatus.success);
    expect(state.lastSuccessAt, isNotNull);
    expect(state.lastAttemptAt, isNotNull);
    expect(state.pendingUploadCount, 0);
    expect(state.message, '日程同步完成');
    expect(state.source, '日程页');
  });

  test('待上传数量是绝对值，连续编辑不会累加', () {
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      scopeResolver: (_) => 'g',
    );
    addTearDown(coordinator.dispose);

    coordinator.markPending(SyncModule.schedule, uploadCount: 3);
    coordinator.markPending(SyncModule.schedule, uploadCount: 3);
    expect(coordinator.stateFor(SyncModule.schedule).pendingUploadCount, 3);
  });

  test('失败会保留上一次成功时间并累加失败次数', () {
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      scopeResolver: (_) => 'g',
    );
    addTearDown(coordinator.dispose);

    coordinator.report(
      SyncModule.travel,
      const SyncOperationResult.success(message: '出行记录已同步'),
    );
    final firstSuccess = coordinator.stateFor(SyncModule.travel).lastSuccessAt;
    expect(firstSuccess, isNotNull);

    coordinator.report(
      SyncModule.travel,
      const SyncOperationResult.failed('出行同步失败：网络错误'),
    );

    final failed = coordinator.stateFor(SyncModule.travel);
    expect(failed.status, SyncModuleStatus.failed);
    expect(failed.lastSuccessAt, firstSuccess);
    expect(failed.failureCount, 1);
    expect(failed.message, '出行同步失败：网络错误');
  });

  test('不同身份的同步状态互相隔离', () {
    var scope = 'g';
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      scopeResolver: (_) => scope,
    );
    addTearDown(coordinator.dispose);

    coordinator.report(
      SyncModule.schedule,
      const SyncOperationResult.success(message: '日程同步完成'),
    );
    expect(
      coordinator.stateFor(SyncModule.schedule).status,
      SyncModuleStatus.success,
    );

    // 切换到另一个身份后不能继承上一个身份的同步时间。
    scope = 'j';
    final other = coordinator.stateFor(SyncModule.schedule);
    expect(other.status, SyncModuleStatus.idle);
    expect(other.lastSuccessAt, isNull);
    expect(coordinator.recordedContextCount, 1);
  });

  test('状态会按上下文持久化并在重启后恢复', () async {
    final store = InMemorySyncStatusStore();
    final first = SyncStatusCoordinator(
      store: store,
      scopeResolver: (_) => 'g',
    );
    first.report(
      SyncModule.diary,
      const SyncOperationResult.success(message: '日记已同步'),
    );
    // 等待链式落盘完成
    await Future<void>.delayed(Duration.zero);
    first.dispose();

    final second = SyncStatusCoordinator(
      store: store,
      scopeResolver: (_) => 'g',
    );
    addTearDown(second.dispose);
    await second.initialize();

    final restored = second.stateFor(SyncModule.diary);
    expect(restored.status, SyncModuleStatus.success);
    expect(restored.lastSuccessAt, isNotNull);
    expect(restored.message, '日记已同步');
  });

  test('v1 旧状态迁移后不会被当作当前身份的成功记录', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SharedPreferencesSyncStatusStore.legacyStorageKey: '{"schedule":'
          '{"enabled":true,"status":"success",'
          '"lastSyncAt":"2026-09-01T10:00:00.000",'
          '"pendingUploadCount":0,"pendingDownloadCount":0,'
          '"failureCount":0,"conflictCount":0}}',
    });

    final coordinator = SyncStatusCoordinator();
    addTearDown(coordinator.dispose);
    await coordinator.initialize();

    final state = coordinator.stateFor(SyncModule.schedule);
    expect(state.lastSuccessAt, isNull);
    expect(state.status, SyncModuleStatus.idle);
  });

  test('业务层的 busy 结果不会累加失败次数', () {
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      scopeResolver: (_) => 'g',
    );
    addTearDown(coordinator.dispose);

    coordinator.report(
      SyncModule.travel,
      const SyncOperationResult.busy('已有出行同步任务'),
    );

    final state = coordinator.stateFor(SyncModule.travel);
    expect(state.status, SyncModuleStatus.busy);
    expect(state.failureCount, 0);
    expect(state.lastAttemptAt, isNull);
  });
}
