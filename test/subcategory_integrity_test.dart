import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/schedule_template.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/category_sync_dependencies.dart';
import 'package:time_manager/services/schedule_day_merge.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/target_sync_dependencies.dart';

final study = Category(
  id: 'study',
  name: '学习',
  color: Colors.blue,
  subCategories: const ['阅读', '英语'],
  hiddenSubCategories: const ['复习'],
  updatedAt: 1,
);
final work = Category(
  id: 'work',
  name: '工作',
  color: Colors.green,
  subCategories: const ['阅读'],
  updatedAt: 1,
);

String dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

Future<TimeProvider> createProvider(
    {bool includeAmbiguousLegacy = false,
    bool useSavedPreferences = false}) async {
  final now = DateTime.now();
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  final goals = [
    for (final category in [study, work])
      Target(
        id: 'goal-${category.id}',
        name: '阅读',
        categoryId: category.id,
        type: TargetType.duration,
        color: category.color,
        period: '每天',
        durationHours: 1,
        updatedAt: 1,
      ),
  ];
  final template = ScheduleTemplate(
    id: 'template',
    name: '日程模板',
    createdAt: 1,
    slots: [
      TemplateSlot(index: 0, label: '阅读', categoryId: study.id),
      TemplateSlot(index: 1, label: '英语', categoryId: study.id),
      TemplateSlot(index: 2, label: '阅读', categoryId: work.id),
    ],
  );
  if (!useSavedPreferences) {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'g',
      'categories': [jsonEncode(study.toJson()), jsonEncode(work.toJson())],
      'targets': goals.map((goal) => jsonEncode(goal.toJson())).toList(),
      'schedule_templates': jsonEncode([template.toJson()]),
      'daily_slots': jsonEncode({
        dateKey(now): [
          {'i': 0, 'l': '阅读', 'cid': study.id, 'ts': 1},
          {'i': 1, 'l': '英语', 'cid': study.id, 'ts': 1},
          {'i': 2, 'l': '阅读', 'cid': work.id, 'ts': 1},
          if (includeAmbiguousLegacy) {'i': 3, 'l': '阅读', 'ts': 1},
        ],
        dateKey(yesterday): [
          {'i': 0, 'l': '阅读', 'cid': study.id, 'ts': 1},
        ],
      }),
    });
  }
  final provider = TimeProvider(
    identityModePlatformOverride: false,
    googleCalendarSyncPlatformOverride: false,
    localSaveDebounce: const Duration(hours: 1),
    scheduleGiteeDebounce: const Duration(hours: 1),
    categorySyncDependencies: CategorySyncDependencies.disabled(),
    targetSyncDependencies: TargetSyncDependencies.disabled(),
    scheduleSyncDependencies: ScheduleSyncDependencies(
      loadToken: () async => null,
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.error('offline'),
      pullDay: ({required token, required dateKey, required userCode}) async =>
          ScheduleGiteePullResult.error('offline'),
    ),
  );
  await provider.waitForSyncReady();
  addTearDown(provider.dispose);
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });
  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  test('调整子事件顺序不会修改历史记录、目标和模板', () async {
    final provider = await createProvider();
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    final result = provider.updateCategoryWithResult(
      index,
      study.copyWith(subCategories: ['英语', '阅读']),
    );
    expect(result.isSuccess, isTrue);
    expect(
        provider.slots.take(3).map((slot) => slot.label), ['阅读', '英语', '阅读']);
    expect(provider.targets.map((target) => target.name), ['阅读', '阅读']);
    expect(provider.templates.single.slots.map((slot) => slot.label),
        ['阅读', '英语', '阅读']);
    expect(provider.pendingGiteeSyncDates, isEmpty);
  });

  test('同次删除并新增不会误改其他子事件，旧记录保留为已删除', () async {
    final provider = await createProvider();
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    expect(
      provider.updateCategory(
          index, study.copyWith(subCategories: ['英语', '编程'])),
      isTrue,
    );
    expect(
        provider.slots.take(3).map((slot) => slot.label), ['阅读', '英语', '阅读']);
    expect(
        provider.deletedEventRelations.any((relation) =>
            relation.categoryId == study.id && relation.eventName == '阅读'),
        isTrue);
    final stats = provider.getParentStatistics(
        provider.currentDate, provider.currentDate);
    expect(stats['已删除'], closeTo(1 / 6, 1e-9));
    expect(stats['学习'], closeTo(1 / 6, 1e-9));
    expect(stats['工作'], closeTo(1 / 6, 1e-9));
  });

  test('明确改名只更新所属父事件，保存并登记每个受影响日期的同步归属', () async {
    final provider = await createProvider();
    final today = provider.currentDate;
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    final result = provider.updateCategoryWithResult(
      index,
      study.copyWith(subCategories: ['英语', '读书']),
      subCategoryRenames: {'阅读': '读书'},
    );
    expect(result.isSuccess, isTrue);
    expect(
        provider.slots.take(3).map((slot) => slot.label), ['读书', '英语', '阅读']);
    expect(provider.slotsForDate(yesterday)[0].label, '读书');
    expect(
        provider.slots[0].modifiedAt!.millisecondsSinceEpoch, greaterThan(1));
    expect(provider.targets.map((target) => target.name), ['读书', '阅读']);
    expect(provider.templates.single.slots.map((slot) => slot.label),
        ['读书', '英语', '阅读']);
    expect(provider.pendingGiteeSyncDates,
        containsAll([dateKey(today), dateKey(yesterday)]));
    expect(await provider.retryLocalSave(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(prefs.getString('daily_slots')!) as Map<String, dynamic>;
    expect((saved[dateKey(yesterday)] as List).first['l'], '读书');
    final owners = jsonDecode(prefs.getString('pending_gitee_sync_owners')!);
    expect(owners[dateKey(today)], contains('g'));
    expect(owners[dateKey(yesterday)], contains('g'));
  });

  test('批量改名不会覆盖本机尚未拉取的远端新时间记录', () async {
    final provider = await createProvider();
    final oldVersion = provider.slots[0].modifiedAt!.millisecondsSinceEpoch;
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    final result = provider.updateCategoryWithResult(
      index,
      study.copyWith(subCategories: ['读书', '英语']),
      subCategoryRenames: {'阅读': '读书'},
    );
    expect(result.isSuccess, isTrue);
    final renamed = {
      'i': 0,
      'l': provider.slots[0].label,
      'cid': study.id,
      'ts': provider.slots[0].modifiedAt!.millisecondsSinceEpoch,
    };
    final oldRemote = {'i': 0, 'l': '阅读', 'cid': study.id, 'ts': oldVersion};
    final newerRemote = {
      'i': 0,
      'l': '会议',
      'cid': work.id,
      'ts': oldVersion + 2
    };
    expect(
        scheduleEntriesForPush(
            localEntries: [renamed], remoteEntries: [oldRemote]).single['l'],
        '读书');
    expect(
        scheduleEntriesForPush(
            localEntries: [renamed], remoteEntries: [newerRemote]).single['l'],
        '会议');
  });

  test('显式交换两个名称时按原始名称同时映射，不发生链式合并', () async {
    final provider = await createProvider();
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    final result = provider.updateCategoryWithResult(
      index,
      study.copyWith(subCategories: ['英语', '阅读']),
      subCategoryRenames: {'阅读': '英语', '英语': '阅读'},
    );
    expect(result.isSuccess, isTrue);
    expect(
        provider.slots.take(3).map((slot) => slot.label), ['英语', '阅读', '阅读']);
    expect(provider.templates.single.slots.map((slot) => slot.label),
        ['英语', '阅读', '阅读']);
  });

  test('改名后撤销时间编辑不会从旧快照恢复旧名称', () async {
    final provider = await createProvider();
    provider.assignCategoryToSlots({5}, study, subLabel: '英语');
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    final result = provider.updateCategoryWithResult(
      index,
      study.copyWith(subCategories: ['读书', '英语']),
      subCategoryRenames: {'阅读': '读书'},
    );
    expect(result.isSuccess, isTrue);
    provider.undo();
    expect(provider.slots[0].label, '读书');
    expect(provider.slots[5].recorded, isFalse);
  });

  test('错误的改名映射或过期编辑不会改写数据', () async {
    final provider = await createProvider();
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    final stale = study.copyWith(updatedAt: 999);
    expect(
        provider
            .updateCategoryWithResult(index, study, expectedCategory: stale)
            .isSuccess,
        isFalse);
    expect(
        provider.updateCategoryWithResult(index, study,
            subCategoryRenames: {'不存在': '阅读'}).isSuccess,
        isFalse);
    expect(
        provider.slots.take(3).map((slot) => slot.label), ['阅读', '英语', '阅读']);
  });

  test('没有父 ID 的同名旧记录不猜测归属，改名时安全拒绝', () async {
    final provider = await createProvider(includeAmbiguousLegacy: true);
    expect(provider.slots[3].categoryId, isNull);
    expect(provider.resolveCategoryIdForLabel('阅读'), isNull);
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    final result = provider.updateCategoryWithResult(
      index,
      study.copyWith(subCategories: ['读书', '英语']),
      subCategoryRenames: {'阅读': '读书'},
    );
    expect(result.isSuccess, isFalse);
    expect(result.error, contains('无法确定所属父事件'));
    expect(provider.slots[0].label, '阅读');
    expect(provider.slots[3].label, '阅读');
    expect(provider.slots[3].categoryId, isNull);
  });

  test('同名旧记录缺少父 ID 时，删除一侧后也不会被归给另一侧', () async {
    final provider = await createProvider(includeAmbiguousLegacy: true);
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    expect(
        provider.updateCategory(index, study.copyWith(subCategories: ['英语'])),
        isTrue);
    final today = provider.currentDate;
    final stats = provider.getParentStatistics(today, today);
    expect(stats['工作'], closeTo(1 / 6, 1e-9));
    expect(stats['已删除'], closeTo(1 / 6, 1e-9));
    expect(stats['临时'], closeTo(1 / 6, 1e-9));
    expect(provider.resolveCategoryIdForLabel('阅读'), isNull);
    expect(await provider.retryLocalSave(), isTrue);
    final restored = await createProvider(useSavedPreferences: true);
    expect(restored.slots[3].categoryId, isNull);
    final restoredStats = restored.getParentStatistics(today, today);
    expect(restoredStats['工作'], closeTo(1 / 6, 1e-9));
    expect(restoredStats['已删除'], closeTo(1 / 6, 1e-9));
    expect(restoredStats['临时'], closeTo(1 / 6, 1e-9));
  });

  test('改名不能占用已删除子事件的名称并合并其历史', () async {
    final provider = await createProvider();
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    expect(
        provider.updateCategory(index, study.copyWith(subCategories: ['阅读'])),
        isTrue);
    final current = provider.categories[index];
    final result = provider.updateCategoryWithResult(
      index,
      current.copyWith(subCategories: ['英语']),
      subCategoryRenames: {'阅读': '英语'},
    );
    expect(result.isSuccess, isFalse);
    expect(result.error, contains('已有其他事件的历史数据'));
    expect(
        provider.slots.take(3).map((slot) => slot.label), ['阅读', '英语', '阅读']);
  });

  test('同名子事件删除后只将原父事件的记录归入已删除', () async {
    final provider = await createProvider();
    final index = provider.categories.indexWhere((item) => item.id == study.id);
    final today = provider.currentDate;
    expect(
        provider.getParentStatistics(today, today)['学习'], closeTo(1 / 3, 1e-9));
    provider.updateCategory(index, study.copyWith(subCategories: ['英语']));
    final grouped = provider.getStatisticsWithTemporaryGrouped(today, today);
    expect(grouped['已删除'], closeTo(1 / 6, 1e-9));
    expect(grouped['阅读'], closeTo(1 / 6, 1e-9));
    final withoutDeleted = provider
        .getStatisticsWithTemporaryGrouped(today, today, includeDeleted: false);
    expect(withoutDeleted['阅读'], closeTo(1 / 6, 1e-9));
    final deletedHistory = provider.getEventHistory('已删除', 0);
    final items = deletedHistory.values.expand((items) => items).toList();
    expect(items, hasLength(1));
    expect(items.single.parentName, '学习');
    final liveHistory = provider.getEventHistory('阅读', 0);
    final liveItems = liveHistory.values.expand((items) => items).toList();
    expect(liveItems, hasLength(1));
    expect(liveItems.single.range, '00:20 - 00:30');
    final separateHistory =
        provider.getEventHistory('阅读', 0, groupDeleted: false);
    expect(separateHistory.values.expand((items) => items), hasLength(2));
    final workHistory = provider.getEventHistory('工作', 0);
    expect(workHistory.values.expand((items) => items), hasLength(1));
  });
}
