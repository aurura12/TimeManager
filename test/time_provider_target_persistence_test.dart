import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/target_gitee_service.dart';
import 'package:time_manager/services/target_sync_dependencies.dart';

ScheduleSyncDependencies _offlineScheduleDependencies() {
  return ScheduleSyncDependencies(
    loadToken: () async => null,
    listPaths: ({required token, required userCode}) async {
      return ScheduleGiteeListWithShaResult.error('offline');
    },
    pullDay: ({required token, required dateKey, required userCode}) async {
      return ScheduleGiteePullResult.error('offline');
    },
  );
}

TargetSyncDependencies _offlineTargetDependencies() {
  return TargetSyncDependencies(
    loadToken: () async => null,
    pullTargets: ({required token, required userCode}) async {
      return TargetGiteePullResult.notFound();
    },
    pushTargets: ({
      required token,
      required userCode,
      required content,
      required commitMessage,
    }) async {
      return TargetGiteePushResult.success(created: false);
    },
  );
}

Target makeTarget(String id, String name) {
  return Target(
    id: id,
    name: name,
    type: TargetType.duration,
    color: const Color(0xFF9CB86A),
    period: '每天',
    durationHours: 1,
  );
}

Future<TimeProvider> createProvider(Map<String, Object> preferences) async {
  SharedPreferences.setMockInitialValues(preferences);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  final provider = TimeProvider(
    identityModePlatformOverride: true,
    scheduleSyncDependencies: _offlineScheduleDependencies(),
    targetSyncDependencies: _offlineTargetDependencies(),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppIdentityService.resetForTesting();
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  test('加载旧目标时迁移出正的更新时间', () async {
    final legacy = makeTarget('legacy', '旧目标').toJson()..remove('updatedAt');
    final provider = await createProvider({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
      'identity_j_targets': [json.encode(legacy)],
    });
    addTearDown(provider.dispose);

    expect(provider.targets.single.updatedAt, greaterThan(0));
  });

  test('新增目标会保存更新时间和文档时间', () async {
    final provider = await createProvider({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    addTearDown(provider.dispose);

    provider.addTarget(makeTarget('new', '新目标'));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final prefs = await SharedPreferences.getInstance();
    final savedTarget = json.decode(
      prefs.getStringList('identity_j_targets')!.single,
    ) as Map<String, dynamic>;
    expect(savedTarget['updatedAt'], greaterThan(0));
    expect(
      prefs.getInt('identity_j_targets_doc_updated_at'),
      greaterThan(0),
    );
  });

  test('删除目标会保存删除墓碑，排序会更新文档时间', () async {
    final provider = await createProvider({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    addTearDown(provider.dispose);

    provider.addTarget(makeTarget('a', 'A'));
    provider.addTarget(makeTarget('b', 'B'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final prefs = await SharedPreferences.getInstance();
    final beforeReorder = prefs.getInt('identity_j_targets_doc_updated_at')!;

    provider.reorderTargets(0, 1);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final afterReorder = prefs.getInt('identity_j_targets_doc_updated_at')!;
    expect(afterReorder, greaterThanOrEqualTo(beforeReorder));

    provider.deleteTarget(provider.targets.first);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final deleted = json.decode(
      prefs.getString('identity_j_deleted_targets')!,
    ) as Map<String, dynamic>;
    expect(deleted, hasLength(1));
    expect(deleted.values.single, greaterThan(0));
  });
}
