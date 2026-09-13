import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/category_document_merge.dart';
import 'package:time_manager/services/category_gitee_service.dart';
import 'package:time_manager/services/category_sync_dependencies.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';

class _CategoryRemoteState {
  final Map<String, String> contents = {};
  final List<String> pullRequests = [];
}

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

CategorySyncDependencies _categoryDependencies(_CategoryRemoteState state) {
  return CategorySyncDependencies(
    loadToken: () async => 'fake-token',
    pullCategories: ({required token, required userCode}) async {
      state.pullRequests.add(userCode);
      final content = state.contents[userCode];
      if (content == null) return CategoryGiteePullResult.notFound();
      return CategoryGiteePullResult.success(content, 'sha-$userCode');
    },
  );
}

CategoryDocument _remoteDocument(String id, String name) {
  return CategoryDocument(
    updatedAt: 200,
    categories: [
      Category(
        id: id,
        name: name,
        color: Colors.blue,
        updatedAt: 200,
      ),
    ],
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

Future<TimeProvider> _createProvider(_CategoryRemoteState state) async {
  SharedPreferences.setMockInitialValues({
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: DiaryKind.g.code,
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  final provider = TimeProvider(
    identityModePlatformOverride: true,
    googleCalendarSyncPlatformOverride: false,
    scheduleSyncDependencies: _offlineScheduleDependencies(),
    categorySyncDependencies: _categoryDependencies(state),
  );
  await _waitUntil(() => provider.isInitialLoadFinished);
  await _waitUntil(() => state.pullRequests.isNotEmpty);
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppIdentityService.resetForTesting);

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  test('回到前台时在冷却时间内不会重复拉取分类', () async {
    final state = _CategoryRemoteState();
    state.contents['g'] = encodeCategoryDocument(
      _remoteDocument('g-remote', '远端分类'),
      nowMs: 200,
    );
    final provider = await _createProvider(state);
    addTearDown(provider.dispose);

    expect(state.pullRequests, ['g']);
    expect(provider.categories.any((c) => c.name == '远端分类'), isTrue);

    await provider.onAppResumed();
    expect(state.pullRequests, ['g']);
  });

  test('切换身份后强制拉取新身份的分类', () async {
    final state = _CategoryRemoteState();
    state.contents['g'] = encodeCategoryDocument(
      _remoteDocument('g-remote', '乖乖分类'),
      nowMs: 200,
    );
    state.contents['j'] = encodeCategoryDocument(
      _remoteDocument('j-remote', '晶晶分类'),
      nowMs: 300,
    );
    final provider = await _createProvider(state);
    addTearDown(provider.dispose);

    await provider.setScheduleUser(DiaryKind.j);
    await _waitUntil(() => state.pullRequests.length >= 2);

    expect(state.pullRequests, ['g', 'j']);
    expect(provider.categories.any((c) => c.name == '晶晶分类'), isTrue);
  });

  test('手动同步会强制刷新分类', () async {
    final state = _CategoryRemoteState();
    state.contents['g'] = encodeCategoryDocument(
      _remoteDocument('g-remote', '远端分类'),
      nowMs: 200,
    );
    final provider = await _createProvider(state);
    addTearDown(provider.dispose);

    await provider.syncAll();

    await _waitUntil(() => state.pullRequests.length >= 2);
    expect(state.pullRequests, ['g', 'g']);
  });
}
