import 'dart:convert';

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

Future<TimeProvider> _createProvider(
  _CategoryRemoteState state, {
  Map<String, Object> initialPreferences = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    ...initialPreferences,
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

  test('新增和重命名分类时阻止重复名称，并规范首尾空白', () async {
    final state = _CategoryRemoteState();
    final provider = await _createProvider(state);
    addTearDown(provider.dispose);

    expect(
      provider.addCategory(
        Category(
          name: '  新分类  ',
          color: Colors.blue,
          subCategories: [' 子事件 '],
        ),
      ),
      isTrue,
    );
    final added = provider.categories.last;
    expect(added.name, '新分类');
    expect(added.subCategories, ['子事件']);

    expect(
      provider.addCategory(Category(name: '新分类', color: Colors.red)),
      isFalse,
    );
    expect(
      provider.categories.where((category) => category.name == '新分类'),
      hasLength(1),
    );

    expect(
      provider.addCategory(Category(name: '另一个分类', color: Colors.green)),
      isTrue,
    );
    final secondIndex = provider.categories
        .lastIndexWhere((category) => category.name == '另一个分类');
    final second = provider.categories[secondIndex];
    expect(
      provider.updateCategory(
        secondIndex,
        Category(id: second.id, name: ' 新分类 ', color: Colors.green),
      ),
      isFalse,
    );
    expect(provider.categories[secondIndex].name, '另一个分类');
  });

  test('同一分类内阻止重复子事件（包括可见和隐藏列表）', () async {
    final state = _CategoryRemoteState();
    final provider = await _createProvider(state);
    addTearDown(provider.dispose);

    expect(
      provider.addCategory(
        Category(
          name: '父事件',
          color: Colors.blue,
          subCategories: ['会议'],
          hiddenSubCategories: [' 会议 '],
        ),
      ),
      isFalse,
    );
    expect(
        provider.categories.any((category) => category.name == '父事件'), isFalse);
  });

  test('启动加载会规范化存量同名分类并迁移时间块分类 ID', () async {
    final state = _CategoryRemoteState();
    final oldCategory = Category(
      id: 'old-category',
      name: ' 工作 ',
      color: Colors.blue,
      updatedAt: 100,
    );
    final newCategory = Category(
      id: 'new-category',
      name: '工作',
      color: Colors.red,
      updatedAt: 200,
    );
    final provider = await _createProvider(
      state,
      initialPreferences: {
        AppIdentityResolver.dataKey(DiaryKind.g, 'categories'): [
          jsonEncode(oldCategory.toJson()),
          jsonEncode(newCategory.toJson())
        ],
        AppIdentityResolver.dataKey(DiaryKind.g, 'daily_slots'): jsonEncode({
          '2026-09-06': [
            {
              'i': 0,
              'l': '工作',
              'cid': 'old-category',
              'c': Colors.blue.toARGB32(),
              'ts': 300,
            },
          ],
        }),
      },
    );
    addTearDown(provider.dispose);

    final workCategories =
        provider.categories.where((category) => category.name == '工作').toList();
    expect(workCategories, hasLength(1));
    expect(workCategories.single.id, 'new-category');
    expect(
        provider.getSlotsForDate('2026-09-06')![0].categoryId, 'new-category');
  });

  test('启动加载空 ID 同名分类时保留较新载荷和有效引用 ID', () async {
    final state = _CategoryRemoteState();
    final newerWithoutId = Category(
      id: '',
      name: '工作',
      color: Colors.red,
      updatedAt: 500,
    );
    final olderWithId = Category(
      id: 'local1',
      name: ' 工作 ',
      color: Colors.blue,
      updatedAt: 100,
    );
    final provider = await _createProvider(
      state,
      initialPreferences: {
        AppIdentityResolver.dataKey(DiaryKind.g, 'categories'): [
          jsonEncode(newerWithoutId.toJson()),
          jsonEncode(olderWithId.toJson()),
        ],
        AppIdentityResolver.dataKey(DiaryKind.g, 'daily_slots'): jsonEncode({
          '2026-09-06': [
            {
              'i': 0,
              'l': '工作',
              'cid': 'local1',
              'c': Colors.blue.toARGB32(),
              'ts': 300,
            },
          ],
        }),
      },
    );
    addTearDown(provider.dispose);

    final workCategories =
        provider.categories.where((category) => category.name == '工作').toList();
    expect(workCategories, hasLength(1));
    expect(workCategories.single.id, 'local1');
    expect(
      workCategories.single.color.toARGB32(),
      Colors.red.toARGB32(),
    );
    expect(
      provider.getSlotsForDate('2026-09-06')![0].categoryId,
      'local1',
    );
  });

  test('备份导入会合并同名分类并迁移时间块分类 ID', () async {
    final state = _CategoryRemoteState();
    final provider = await _createProvider(state);
    addTearDown(provider.dispose);

    final backup = {
      'version': TimeProvider.backupVersion,
      'categories': [
        Category(
          id: 'old-category',
          name: ' 工作 ',
          color: Colors.blue,
          updatedAt: 100,
        ).toJson(),
        Category(
          id: 'new-category',
          name: '工作',
          color: Colors.red,
          updatedAt: 200,
        ).toJson(),
      ],
      'dailySlots': {
        '2026-09-06': [
          {
            'i': 0,
            'l': '工作',
            'cid': 'old-category',
            'c': Colors.blue.toARGB32(),
            'ts': 300,
          },
        ],
      },
    };

    await provider.importBackupJson(jsonEncode(backup));

    final workCategories =
        provider.categories.where((category) => category.name == '工作').toList();
    expect(workCategories, hasLength(1));
    expect(workCategories.single.id, 'new-category');
    expect(
        provider.getSlotsForDate('2026-09-06')![0].categoryId, 'new-category');
  });
}
