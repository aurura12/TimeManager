import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/diary_gitee_service.dart';
import 'package:time_manager/services/diary_local_store.dart';
import 'package:time_manager/services/diary_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final date = DateTime(2026, 3, 5);

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

  tearDown(AppIdentityService.resetForTesting);

  Future<void> saveDraft(String body) async {
    await DiaryLocalStore.saveDraftBody(DiaryKind.g, date, body);
    await DiaryLocalStore.saveDraftStartedAt(
      DiaryKind.g,
      date,
      DateTime(2026, 3, 5, 9),
    );
    await DiaryLocalStore.markDraftPending(DiaryKind.g, date);
  }

  DiarySyncService serviceFor({
    DiaryGiteeListWithShaResult Function()? listing,
    DiaryGiteePullResult Function(String path)? pull,
    DiaryGiteePushResult Function({
      required String path,
      required String content,
      String? expectedSha,
      required bool expectNotFound,
    })? push,
    void Function()? onListing,
  }) {
    return DiarySyncService(
      tokenLoader: () async => 'token',
      listLoader: (_) async {
        onListing?.call();
        return listing?.call() ??
            DiaryGiteeListWithShaResult.success({
              'G2026年3月5日.md': 'sha-old',
            });
      },
      pullLoader: ({required token, required path}) async =>
          pull?.call(path) ??
          DiaryGiteePullResult.success('旧远端正文', 'sha-old'),
      pushLoader: ({
        required token,
        required path,
        required content,
        required commitMessage,
        expectedSha,
        expectNotFound = false,
      }) async {
        return push?.call(
              path: path,
              content: content,
              expectedSha: expectedSha,
              expectNotFound: expectNotFound,
            ) ??
            DiaryGiteePushResult.success(created: false, sha: 'sha-new');
      },
      cacheUpdater: (_, __, ___) async {},
      cacheRefresher: (_) async {},
    );
  }

  test('用本地内容覆盖远端：带上远端当前 sha 推送并清理待上传', () async {
    await saveDraft('本地正文');
    String? pushedContent;
    String? pushedSha;
    var pushedPath = '';
    final service = serviceFor(
      push: ({
        required path,
        required content,
        expectedSha,
        required expectNotFound,
      }) {
        pushedPath = path;
        pushedContent = content;
        pushedSha = expectedSha;
        expect(expectNotFound, isFalse, reason: '远端已存在时不能按新建推送');
        return DiaryGiteePushResult.success(created: false, sha: 'sha-new');
      },
    );

    final result = await service.overwriteRemote(kind: DiaryKind.g, date: date);

    expect(result.status, SyncModuleStatus.success);
    expect(pushedPath, 'G2026年3月5日.md');
    expect(pushedSha, 'sha-old');
    expect(pushedContent, contains('本地正文'));
    expect(await DiaryLocalStore.isDraftPending(DiaryKind.g, date), isFalse);
    final baseline = await DiaryLocalStore.loadRemoteBaseline(DiaryKind.g, date);
    expect(baseline?.sha, 'sha-new');
  });

  test('传入 body 时以传入正文为准（合并结果）', () async {
    await saveDraft('编辑器里的旧内容');
    String? pushedContent;
    final service = serviceFor(
      push: ({
        required path,
        required content,
        expectedSha,
        required expectNotFound,
      }) {
        pushedContent = content;
        return DiaryGiteePushResult.success(created: false, sha: 'sha-new');
      },
    );

    await service.overwriteRemote(
      kind: DiaryKind.g,
      date: date,
      body: '合并后的正文',
    );

    expect(pushedContent, contains('合并后的正文'));
    expect(pushedContent, isNot(contains('编辑器里的旧内容')));
  });

  test('传入 path 时不再列目录，直接按该路径推送', () async {
    await saveDraft('本地正文');
    var listings = 0;
    var pushedPath = '';
    final service = serviceFor(
      onListing: () => listings++,
      pull: (path) => DiaryGiteePullResult.success('远端正文', 'sha-pinned'),
      push: ({
        required path,
        required content,
        expectedSha,
        required expectNotFound,
      }) {
        pushedPath = path;
        return DiaryGiteePushResult.success(created: false, sha: 'sha-new');
      },
    );

    await service.overwriteRemote(
      kind: DiaryKind.g,
      date: date,
      path: '自定义/G2026年3月5日.md',
    );

    expect(listings, 0);
    expect(pushedPath, '自定义/G2026年3月5日.md');
  });

  test('查看冲突期间远端又变了：拒绝覆盖且不推送', () async {
    await saveDraft('本地正文');
    var pushes = 0;
    final service = serviceFor(
      pull: (_) => DiaryGiteePullResult.success('别人刚写的内容', 'sha-latest'),
      push: ({
        required path,
        required content,
        expectedSha,
        required expectNotFound,
      }) {
        pushes++;
        return DiaryGiteePushResult.success(created: false, sha: 'sha-new');
      },
    );

    final result = await service.overwriteRemote(
      kind: DiaryKind.g,
      date: date,
      expectedRemoteSha: 'sha-when-viewed',
    );

    expect(result.status, SyncModuleStatus.conflict);
    expect(pushes, 0);
    expect(await DiaryLocalStore.isDraftPending(DiaryKind.g, date), isTrue);
  });

  test('远端正文与本地一致时不产生新提交', () async {
    await saveDraft('同样的正文');
    var pushes = 0;
    final service = serviceFor(
      pull: (_) => DiaryGiteePullResult.success('同样的正文', 'sha-same'),
      push: ({
        required path,
        required content,
        expectedSha,
        required expectNotFound,
      }) {
        pushes++;
        return DiaryGiteePushResult.success(created: false, sha: 'sha-new');
      },
    );

    final result = await service.overwriteRemote(kind: DiaryKind.g, date: date);

    expect(result.status, SyncModuleStatus.success);
    expect(pushes, 0);
    expect(await DiaryLocalStore.isDraftPending(DiaryKind.g, date), isFalse);
  });

  test('只读分区不能覆盖远端', () async {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    AppIdentityService.resetForTesting();
    final service = serviceFor();

    final result = await service.overwriteRemote(kind: DiaryKind.g, date: date);

    expect(result.status, SyncModuleStatus.skipped);
  });

  test('没有正文时不推送', () async {
    var pushes = 0;
    final service = serviceFor(
      push: ({
        required path,
        required content,
        expectedSha,
        required expectNotFound,
      }) {
        pushes++;
        return DiaryGiteePushResult.success(created: false, sha: 'sha-new');
      },
    );

    final result = await service.overwriteRemote(kind: DiaryKind.g, date: date);

    expect(result.status, SyncModuleStatus.skipped);
    expect(pushes, 0);
  });

  test('推送被判冲突时返回 conflict 并保留待上传', () async {
    await saveDraft('本地正文');
    final service = serviceFor(
      push: ({
        required path,
        required content,
        expectedSha,
        required expectNotFound,
      }) =>
          DiaryGiteePushResult.conflict('sha 不匹配'),
    );

    final result = await service.overwriteRemote(kind: DiaryKind.g, date: date);

    expect(result.status, SyncModuleStatus.conflict);
    expect(result.pendingUploadCount, 1);
    expect(await DiaryLocalStore.isDraftPending(DiaryKind.g, date), isTrue);
  });
}
