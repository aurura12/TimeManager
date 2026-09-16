import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/diary_gitee_service.dart';
import 'package:time_manager/services/diary_local_store.dart';
import 'package:time_manager/services/diary_sync_service.dart';
import 'package:time_manager/models/sync_center_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'g',
    });
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  Future<void> saveDraft(String body) async {
    final date = DateTime(2026, 9, 15);
    await DiaryLocalStore.saveDraftBody(DiaryKind.g, date, body);
    await DiaryLocalStore.saveDraftStartedAt(
      DiaryKind.g,
      date,
      DateTime(2026, 9, 15, 8, 30),
    );
    await DiaryLocalStore.markDraftPending(DiaryKind.g, date);
  }

  DiarySyncService serviceFor({
    required DiaryGiteeListWithShaResult Function() listing,
    required DiaryGiteePullResult Function(String path) pull,
    required DiaryGiteePushResult Function(String path) push,
    List<String>? pushedPaths,
  }) {
    return DiarySyncService(
      tokenLoader: () async => 'token',
      listLoader: (_) async => listing(),
      pullLoader: ({required token, required path}) async => pull(path),
      pushLoader: ({
        required token,
        required path,
        required content,
        required commitMessage,
        expectedSha,
        expectNotFound = false,
      }) async {
        pushedPaths?.add(path);
        return push(path);
      },
      cacheUpdater: (_, __, ___) async {},
      cacheRefresher: (_) async {},
    );
  }

  test('同步中心会把本地日记草稿真正推送到远端', () async {
    await saveDraft('今天完成了同步中心改造');
    final pushed = <String>[];
    final service = serviceFor(
      listing: () => DiaryGiteeListWithShaResult.success({}),
      pull: (_) => DiaryGiteePullResult.notFound(),
      push: (_) => DiaryGiteePushResult.success(created: true, sha: 'sha-new'),
      pushedPaths: pushed,
    );

    final result = await service.sync();

    expect(result.status, SyncModuleStatus.success);
    expect(pushed, ['G🛹2026年9月15日.md']);
    final baseline = await DiaryLocalStore.loadRemoteBaseline(
      DiaryKind.g,
      DateTime(2026, 9, 15),
    );
    expect(baseline?.sha, 'sha-new');
    expect(
      await DiaryLocalStore.isDraftPending(
        DiaryKind.g,
        DateTime(2026, 9, 15),
      ),
      isFalse,
    );
  });

  test('远端正文已经一致时不会重复创建提交', () async {
    await saveDraft('同一篇内容');
    final remote = '''
---
title: G🛹2026年9月15日
date: 2026-09-15 08:30:00
tags:
---

同一篇内容
''';
    final pushed = <String>[];
    final service = serviceFor(
      listing: () => DiaryGiteeListWithShaResult.success(
        {'G🛹2026年9月15日.md': 'sha-existing'},
      ),
      pull: (_) => DiaryGiteePullResult.success(remote, 'sha-existing'),
      push: (_) => DiaryGiteePushResult.success(created: false),
      pushedPaths: pushed,
    );

    final result = await service.sync();

    expect(result.status, SyncModuleStatus.success);
    expect(pushed, isEmpty);
  });

  test('同步中心更新的最新基线可供日记页后续推送读取', () async {
    final date = DateTime(2026, 9, 15);
    await saveDraft('同步中心刚推送的内容');
    await DiaryLocalStore.saveRemoteBaseline(
      DiaryKind.g,
      date,
      path: 'G🛹2026年9月15日.md',
      sha: 'sha-before-center',
      notFound: false,
    );
    final service = serviceFor(
      listing: () => DiaryGiteeListWithShaResult.success(
        {'G🛹2026年9月15日.md': 'sha-after-center'},
      ),
      pull: (_) => DiaryGiteePullResult.success(
        '''
---
title: G🛹2026年9月15日
date: 2026-09-15 08:30:00
tags:
---

同步中心刚推送的内容
''',
        'sha-after-center',
      ),
      push: (_) => DiaryGiteePushResult.success(
        created: false,
        sha: 'sha-after-page',
      ),
    );

    await service.sync();

    final pageBaseline = await DiaryLocalStore.loadRemoteBaseline(
      DiaryKind.g,
      date,
    );
    expect(pageBaseline?.sha, 'sha-after-center');
    expect(pageBaseline?.path, 'G🛹2026年9月15日.md');
  });

  test('没有编辑基线时不会覆盖远端不同正文，而是报告冲突', () async {
    await saveDraft('本地新正文');
    final remote = '''
---
title: G🛹2026年9月15日
date: 2026-09-15 08:30:00
tags:
---

远端新正文
''';
    final pushed = <String>[];
    final service = serviceFor(
      listing: () => DiaryGiteeListWithShaResult.success(
        {'G🛹2026年9月15日.md': 'sha-existing'},
      ),
      pull: (_) => DiaryGiteePullResult.success(remote, 'sha-existing'),
      push: (_) => DiaryGiteePushResult.success(created: false),
      pushedPaths: pushed,
    );

    final result = await service.sync();

    expect(result.status, SyncModuleStatus.conflict);
    expect(result.pendingUploadCount, 1);
    expect(pushed, isEmpty);
  });

  test('未标记的历史草稿只刷新索引，不会自动创建远端文件', () async {
    final date = DateTime(2026, 9, 15);
    await DiaryLocalStore.saveDraftBody(DiaryKind.g, date, '历史本地草稿');
    var refreshes = 0;
    final pushed = <String>[];
    final service = DiarySyncService(
      tokenLoader: () async => 'token',
      listLoader: (_) async => DiaryGiteeListWithShaResult.success({}),
      pullLoader: ({required token, required path}) async =>
          DiaryGiteePullResult.notFound(),
      pushLoader: ({
        required token,
        required path,
        required content,
        required commitMessage,
        expectedSha,
        expectNotFound = false,
      }) async {
        pushed.add(path);
        return DiaryGiteePushResult.success(created: true, sha: 'sha');
      },
      cacheUpdater: (_, __, ___) async {},
      cacheRefresher: (_) async => refreshes++,
    );

    final result = await service.sync();

    expect(result.status, SyncModuleStatus.success);
    expect(refreshes, 1);
    expect(pushed, isEmpty);
  });
}
