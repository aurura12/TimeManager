import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/target_document_merge.dart';
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

Target makeTarget(String id, String name, int updatedAt) {
  return Target(
    id: id,
    name: name,
    type: TargetType.duration,
    color: const Color(0xFF9CB86A),
    period: '每天',
    durationHours: 1,
    updatedAt: updatedAt,
  );
}

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

Future<TimeProvider> createProvider(
  Map<String, Object> preferences,
  TargetSyncDependencies targetDependencies,
) async {
  SharedPreferences.setMockInitialValues(preferences);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  final provider = TimeProvider(
    scheduleGiteeDebounce: Duration.zero,
    identityModePlatformOverride: true,
    scheduleSyncDependencies: _offlineScheduleDependencies(),
    targetSyncDependencies: targetDependencies,
  );
  await waitUntil(() => provider.isInitialLoadFinished);
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

  test('启动时拉取并合并远端目标，较新的远端目标胜出', () async {
    var pushCount = 0;
    final remote = TargetDocument(
      updatedAt: 200,
      targets: [makeTarget('a', '远端目标', 300)],
    );
    final dependencies = TargetSyncDependencies(
      loadToken: () async => 'token',
      pullTargets: ({required token, required userCode}) async {
        return TargetGiteePullResult.success(
          encodeTargetDocument(remote, nowMs: remote.updatedAt),
          'sha',
        );
      },
      pushTargets: ({
        required token,
        required userCode,
        required content,
        required commitMessage,
      }) async {
        pushCount++;
        return TargetGiteePushResult.success(created: false);
      },
    );
    final local = makeTarget('a', '本地旧目标', 100).toJson();
    final provider = await createProvider(
      {
        AppIdentityService.modeKey: 'manual',
        AppIdentityService.legacyScheduleUserKey: 'j',
        'identity_j_targets': [json.encode(local)],
      },
      dependencies,
    );
    addTearDown(provider.dispose);

    await waitUntil(() => provider.targets.isNotEmpty);

    expect(provider.targets.single.name, '远端目标');
    expect(pushCount, 0);
  });

  test('卸载重装后首次选择身份可以恢复远端目标', () async {
    final remote = TargetDocument(
      updatedAt: 200,
      targets: [makeTarget('recovered', '恢复目标', 200)],
    );
    var pushCount = 0;
    final dependencies = TargetSyncDependencies(
      loadToken: () async => 'token',
      pullTargets: ({required token, required userCode}) async {
        return TargetGiteePullResult.success(
          encodeTargetDocument(remote, nowMs: remote.updatedAt),
          'sha',
        );
      },
      pushTargets: ({
        required token,
        required userCode,
        required content,
        required commitMessage,
      }) async {
        pushCount++;
        return TargetGiteePushResult.success(created: false);
      },
    );
    final provider = await createProvider(
      {AppIdentityService.modeKey: 'manual'},
      dependencies,
    );
    addTearDown(provider.dispose);

    expect(provider.hasSelectedScheduleUser, isFalse);
    await provider.setScheduleUser(DiaryKind.j);
    await waitUntil(() => provider.targets.isNotEmpty);

    expect(provider.targets.single.name, '恢复目标');
    expect(pushCount, 0);
  });

  test('目标修改会先拉取再推送合并结果', () async {
    final pushedContents = <String>[];
    final dependencies = TargetSyncDependencies(
      loadToken: () async => 'token',
      pullTargets: ({required token, required userCode}) async {
        return TargetGiteePullResult.notFound();
      },
      pushTargets: ({
        required token,
        required userCode,
        required content,
        required commitMessage,
      }) async {
        pushedContents.add(content);
        return TargetGiteePushResult.success(created: true);
      },
    );
    final provider = await createProvider(
      {
        AppIdentityService.modeKey: 'manual',
        AppIdentityService.legacyScheduleUserKey: 'j',
      },
      dependencies,
    );
    addTearDown(provider.dispose);

    provider.addTarget(makeTarget('new', '新目标', 0));
    await waitUntil(() => pushedContents.isNotEmpty);

    final pushed = parseTargetDocument(pushedContents.single);
    expect(pushed.targets.single.name, '新目标');
  });

  test('已有本地目标且远端文件不存在时会完成首次上传', () async {
    final pushedContents = <String>[];
    final dependencies = TargetSyncDependencies(
      loadToken: () async => 'token',
      pullTargets: ({required token, required userCode}) async {
        return TargetGiteePullResult.notFound();
      },
      pushTargets: ({
        required token,
        required userCode,
        required content,
        required commitMessage,
      }) async {
        pushedContents.add(content);
        return TargetGiteePushResult.success(created: true);
      },
    );
    final local = makeTarget('legacy-local', '升级前目标', 100).toJson();
    final provider = await createProvider(
      {
        AppIdentityService.modeKey: 'manual',
        AppIdentityService.legacyScheduleUserKey: 'j',
        'identity_j_targets': [json.encode(local)],
      },
      dependencies,
    );
    addTearDown(provider.dispose);

    await waitUntil(() => pushedContents.isNotEmpty);

    final pushed = parseTargetDocument(pushedContents.single);
    expect(pushed.targets.single.name, '升级前目标');
  });

  test('远端拉取失败时不推送本地目标', () async {
    var pushCount = 0;
    final dependencies = TargetSyncDependencies(
      loadToken: () async => 'token',
      pullTargets: ({required token, required userCode}) async {
        return TargetGiteePullResult.error('403');
      },
      pushTargets: ({
        required token,
        required userCode,
        required content,
        required commitMessage,
      }) async {
        pushCount++;
        return TargetGiteePushResult.success(created: false);
      },
    );
    final provider = await createProvider(
      {
        AppIdentityService.modeKey: 'manual',
        AppIdentityService.legacyScheduleUserKey: 'j',
      },
      dependencies,
    );
    addTearDown(provider.dispose);

    provider.addTarget(makeTarget('blocked', '不要覆盖远端', 0));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(pushCount, 0);
  });
}
