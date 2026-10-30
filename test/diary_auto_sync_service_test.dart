import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/diary_auto_sync_service.dart';
import 'package:time_manager/services/sync_status_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'g',
    });
    AppIdentityService.resetForTesting();
    DiaryAutoSyncService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    DiaryAutoSyncService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  test('没有待上传草稿时直接短路，不触发远端同步', () async {
    var runs = 0;
    final service = DiaryAutoSyncService(
      pendingChecker: () async => false,
      syncRunner: () async {
        runs++;
        return const SyncOperationResult.success();
      },
    );
    final coordinator = SyncStatusCoordinator();

    expect(await service.flush(coordinator: coordinator), isNull);
    expect(runs, 0);
    expect(
        coordinator.stateFor(SyncModule.diary).status, SyncModuleStatus.idle);
    coordinator.dispose();
  });

  test('有待上传草稿时执行一次批量推送并上报成功', () async {
    var runs = 0;
    final service = DiaryAutoSyncService(
      pendingChecker: () async => true,
      syncRunner: () async {
        runs++;
        return const SyncOperationResult.success(message: '日记已同步 1 篇');
      },
    );
    final coordinator = SyncStatusCoordinator();
    await coordinator.initialize();

    final result = await service.flush(coordinator: coordinator);

    expect(runs, 1);
    expect(result?.status, SyncModuleStatus.success);
    final state = coordinator.stateFor(SyncModule.diary);
    expect(state.status, SyncModuleStatus.success);
    expect(state.source, DiaryAutoSyncService.logSource);
    expect(state.lastSuccessAt, isNotNull);
    coordinator.dispose();
  });

  test('并发触发只执行一次推送', () async {
    var runs = 0;
    final gate = Completer<void>();
    final service = DiaryAutoSyncService(
      pendingChecker: () async => true,
      syncRunner: () async {
        runs++;
        await gate.future;
        return const SyncOperationResult.success();
      },
    );

    final first = service.flush();
    final second = service.flush();
    gate.complete();
    await Future.wait([first, second]);

    expect(runs, 1);
  });

  test('未选择身份时保留草稿并上报离线', () async {
    SharedPreferences.setMockInitialValues({});
    AppIdentityService.resetForTesting();
    var runs = 0;
    final service = DiaryAutoSyncService(
      pendingChecker: () async => true,
      syncRunner: () async {
        runs++;
        return const SyncOperationResult.success();
      },
    );
    final coordinator = SyncStatusCoordinator();
    await coordinator.initialize();

    final result = await service.flush(coordinator: coordinator);

    expect(runs, 0);
    expect(result?.status, SyncModuleStatus.offline);
    expect(coordinator.stateFor(SyncModule.diary).status,
        SyncModuleStatus.offline);
    coordinator.dispose();
  });

  test('推送抛错时上报失败而不向上抛出', () async {
    final service = DiaryAutoSyncService(
      pendingChecker: () async => true,
      syncRunner: () async => throw StateError('boom'),
    );
    final coordinator = SyncStatusCoordinator();
    await coordinator.initialize();

    final result = await service.flush(coordinator: coordinator);

    expect(result?.status, SyncModuleStatus.failed);
    expect(result?.pendingUploadCount, 1);
    expect(
        coordinator.stateFor(SyncModule.diary).status, SyncModuleStatus.failed);
    coordinator.dispose();
  });
}
