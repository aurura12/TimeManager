import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/models/target_progress.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/target_sync_dependencies.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';

final category = Category(
    id: 'study',
    name: '学习',
    color: AppSemanticColors.brand,
    subCategories: const ['阅读', '练习'],
    updatedAt: 1);

Target target({String period = '每天', TargetType type = TargetType.duration}) =>
    Target(
        id: DateTime(2026, 10, 1).millisecondsSinceEpoch.toString(),
        name: category.name,
        categoryId: category.id,
        type: type,
        color: category.color,
        period: period,
        compareType: '至少',
        durationHours: 5,
        frequencyCount: 3,
        targetTime: '08:00',
        startTime: '06:00',
        endTime: '24:00');

Future<TimeProvider> providerFor(Target goal) async {
  SharedPreferences.setMockInitialValues({
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'j',
    'identity_j_categories': [jsonEncode(category.toJson())],
    'identity_j_targets': [jsonEncode(goal.toJson())],
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null);
  messenger.setMockMethodCallHandler(
      const MethodChannel('home_widget'), (call) async => null);
  final provider = TimeProvider(
    identityModePlatformOverride: true,
    googleCalendarSyncPlatformOverride: false,
    scheduleGiteeDebounce: const Duration(days: 1),
    localSaveDebounce: const Duration(days: 1),
    saveDataOverride: () async => true,
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
  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);
  final date = DateTime(2026, 10, 6);
  final now = DateTime(2026, 10, 6, 12);

  test('记录编辑、子事件归属和目标值修改立即改变面积与状态', () async {
    final goal = target();
    final provider = await providerFor(goal);
    expect(provider.getTargetDayProgress(goal, date, now: now).hasRecords,
        isFalse);
    provider.assignCategoryToSlots({for (var i = 0; i < 12; i++) i}, category,
        subLabel: '阅读', date: date);
    expect(provider.getTargetDayProgress(goal, date, now: now).ratio,
        closeTo(0.4, 1e-8));
    provider.assignCategoryToSlots({for (var i = 12; i < 30; i++) i}, category,
        subLabel: '练习', date: date);
    expect(
        provider.getTargetDayProgress(goal, date, now: now).isAchieved, isTrue);
    final updated = goal.copyWith(durationHours: 6);
    expect(await provider.updateTarget(updated), isTrue);
    final progress = provider
        .getTargetDayProgress(provider.targetById(goal.id)!, date, now: now);
    expect(progress.ratio, closeTo(5 / 6, 1e-8));
    expect(progress.isAchieved, isFalse);
  });

  test('次数按连续块计，周目标日期格只表示记录，周期配额不摊到每天', () async {
    final goal = target(period: '每周', type: TargetType.frequency);
    final provider = await providerFor(goal);
    provider.assignCategoryToSlots({0, 1, 2, 6}, category, date: date);
    final cycle = provider.getTargetProgress(goal, date: date, now: now);
    expect(cycle.value, 2);
    expect(cycle.ratio, closeTo(2 / 3, 1e-8));
    final day = provider.getTargetDayProgress(goal, date, now: now);
    expect(day.recordOnly, isTrue);
    expect(day.statusLabel, '有记录');
    expect(day.isAchieved, isFalse);
    provider.assignCategoryToSlots({0}, category, date: DateTime(2026, 10, 5));
    expect(provider.getTargetProgress(goal, date: date, now: now).isAchieved,
        isTrue);
  });

  test('删除记录、撤销和重做立即重算历史面积和达标率', () async {
    final goal = target();
    final provider = await providerFor(goal);
    provider.assignCategoryToSlots({for (var i = 0; i < 30; i++) i}, category,
        date: date);
    expect(
        provider.getTargetDayProgress(goal, date, now: now).isAchieved, isTrue);
    provider.undo();
    expect(provider.getTargetDayProgress(goal, date, now: now).hasRecords,
        isFalse);
    expect(
        provider.getTargetAchievementRate(goal, date, DateTime(2026, 10, 7),
            now: now),
        0);
    provider.redo();
    expect(provider.getTargetDayProgress(goal, date, now: now).ratio, 1);
    expect(
        provider.getTargetAchievementRate(goal, date, DateTime(2026, 10, 7),
            now: now),
        1);
  });

  test('上限与等于的达标率只包含已结束且有记录的周期', () async {
    final goal = target().copyWith(compareType: '少于');
    final provider = await providerFor(goal);
    provider.assignCategoryToSlots({for (var i = 0; i < 12; i++) i}, category,
        date: DateTime(2026, 10, 4));
    provider.assignCategoryToSlots({for (var i = 0; i < 30; i++) i}, category,
        date: DateTime(2026, 10, 5));
    provider.assignCategoryToSlots({for (var i = 0; i < 12; i++) i}, category,
        date: date);
    expect(
        provider.getTargetAchievementRate(
            goal, DateTime(2026, 10, 1), DateTime(2026, 10, 7),
            now: now),
        .5);
    final equal = goal.copyWith(compareType: '等于');
    expect(await provider.updateTarget(equal), isTrue);
    expect(
        provider.getTargetAchievementRate(
            equal, DateTime(2026, 10, 1), DateTime(2026, 10, 7),
            now: now),
        .5);
  });

  test('一周内和指定日期范围统计所有区间日期，边界外的记录不参与', () async {
    final goal = target(period: '一周内');
    final provider = await providerFor(goal);
    provider.assignCategoryToSlots({for (var i = 0; i < 12; i++) i}, category,
        date: DateTime(2026, 10, 1));
    provider.assignCategoryToSlots({for (var i = 0; i < 18; i++) i}, category,
        date: date);
    provider.assignCategoryToSlots({for (var i = 0; i < 60; i++) i}, category,
        date: DateTime(2026, 10, 8));
    expect(provider.getTargetProgress(goal, date: date, now: now).value, 5);
    final range = goal.copyWith(period: '2026-10-01~2026-10-06');
    expect(provider.getTargetProgress(range, date: date, now: now).value, 5);
    expect(
        provider
            .getTargetDayProgress(range, DateTime(2026, 10, 8), now: now)
            .status,
        TargetProgressStatus.outsidePeriod);
  });

  test('时间点取区间内首次记录，之后条件失败显示未达标，编辑清缓存', () async {
    final goal = target(type: TargetType.timePoint).copyWith(compareType: '之后');
    final provider = await providerFor(goal);
    provider.assignCategoryToSlots({47, 54}, category, date: date);
    final progress = provider.getTargetDayProgress(goal, date, now: now);
    expect(progress.firstMinute, 470);
    expect(progress.statusLabel, '未达标');
    final updated = goal.copyWith(compareType: '之前');
    expect(await provider.updateTarget(updated), isTrue);
    expect(
        provider
            .getTargetDayProgress(provider.targetById(goal.id)!, date, now: now)
            .isAchieved,
        isTrue);
  });
}
