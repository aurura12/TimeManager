import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';

final _focus = Category(
  id: 'focus',
  name: '专注',
  color: const Color(0xFF9CB86A),
  updatedAt: 1,
);

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class _CountingSlot extends TimeSlot {
  _CountingSlot() : super(hour: 8, minute10: 0, recorded: true, label: '原始');

  int reads = 0;

  @override
  bool get recorded {
    reads++;
    return super.recorded;
  }
}

Future<TimeProvider> _createProvider({bool mobile = false}) async {
  final now = DateTime.now();
  String key(String base) => mobile ? 'identity_g_$base' : base;
  SharedPreferences.setMockInitialValues({
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'g',
    key('categories'): [jsonEncode(_focus.toJson())],
    key('daily_slots'): jsonEncode({
      _dateKey(now): [
        {'i': 48, 'l': '原始', 'ts': 1},
      ],
      _dateKey(DateTime(now.year, now.month, now.day - 1)): [
        {'i': 60, 'l': '昨天', 'ts': 1},
      ],
    }),
    if (mobile) 'identity_j_categories': [jsonEncode(_focus.toJson())],
    if (mobile)
      'identity_j_daily_slots': jsonEncode({
        _dateKey(now): [
          {'i': 48, 'l': '晶晶记录', 'ts': 1},
          {'i': 49, 'l': '晶晶记录', 'ts': 1},
        ],
      }),
  });
  final provider = TimeProvider(
    identityModePlatformOverride: mobile,
    googleCalendarSyncPlatformOverride: false,
    localSaveDebounce: const Duration(hours: 1),
    scheduleSyncDependencies: ScheduleSyncDependencies(
      loadToken: () async => null,
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.error('offline'),
      pullDay: ({required token, required dateKey, required userCode}) async =>
          ScheduleGiteePullResult.error('offline'),
    ),
  );
  addTearDown(provider.dispose);
  await provider.waitForSyncReady();
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });
  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('趋势独立缓存不覆盖分类区间缓存，结果不可修改', () async {
    final provider = await _createProvider();
    final end = provider.currentDate;
    final start = DateTime(end.year, end.month, end.day - 29);
    final counted = _CountingSlot();
    provider.slotsForDate(end)[48] = counted;
    final stats = provider.getStatistics(start, end);
    final daily = provider.getDailyStatistics(start, end);
    expect(daily, hasLength(30));
    expect(daily.last.hours, closeTo(1 / 6, 1e-9));
    expect(daily.last.count, 1);
    expect(daily.first, (hours: 0.0, count: 0));
    expect(() => daily.clear(), throwsUnsupportedError);
    counted.reads = 0;
    expect(provider.getStatistics(start, end), stats);
    expect(counted.reads, 0, reason: '趋势查询不能替换分类区间的缓存');
    provider.getStatistics(end, end);
    counted.reads = 0;
    expect(provider.getDailyStatistics(start, end), same(daily));
    expect(counted.reads, 0, reason: '分类区间切换也不能替换趋势缓存');
  });

  test('词云在同一自然日改变时分秒仍命中缓存', () async {
    final provider = await _createProvider();
    final date = provider.currentDate;
    final counted = _CountingSlot();
    provider.slotsForDate(date)[48] = counted;
    final first = DateTime(date.year, date.month, date.day);
    final counts = provider.getEventOccurrenceCounts(first, first);
    expect(counts, {'原始': 1});
    expect(counted.reads, greaterThan(0));
    counted.reads = 0;
    expect(
      provider.getEventOccurrenceCounts(
        first.add(const Duration(hours: 12)),
        first.add(const Duration(hours: 23, minutes: 59)),
      ),
      counts,
    );
    expect(counted.reads, 0);
    expect(() => counts.clear(), throwsUnsupportedError);
  });

  test('跨日不足24小时仍包含首末两个自然日，缓存口径一致', () async {
    final provider = await _createProvider();
    final date = provider.currentDate;
    final start = DateTime(date.year, date.month, date.day - 1, 23, 59);
    final end = DateTime(date.year, date.month, date.day, 0, 1);
    final stats = provider.getStatistics(start, end);
    expect(stats['昨天'], closeTo(1 / 6, 1e-9));
    expect(stats['原始'], closeTo(1 / 6, 1e-9));
    final daily = provider.getDailyStatistics(start, end);
    expect(daily, hasLength(2));
    expect(daily.every((day) => day.count == 1), isTrue);
    expect(provider.getEventOccurrenceCounts(start, end), {'昨天': 1, '原始': 1});
    expect(provider.getTemporaryLabels(start, end), {'昨天', '原始'});
    expect(
      provider.getStatisticsWithTemporaryGrouped(
          start, end)[TimeProvider.temporaryCategoryName],
      closeTo(1 / 3, 1e-9),
    );
    expect(
      provider.getStatistics(
          DateTime(start.year, start.month, start.day), date),
      stats,
    );
  });

  test('范围外编辑保留缓存，范围内编辑和撤销立即更新趋势与词云', () async {
    final provider = await _createProvider();
    final end = provider.currentDate;
    final start = DateTime(end.year, end.month, end.day - 29);
    final counted = _CountingSlot();
    provider.slotsForDate(end)[48] = counted;
    final daily = provider.getDailyStatistics(start, end);
    final stats = provider.getStatistics(start, end);
    final counts = provider.getEventOccurrenceCounts(start, end);
    provider.assignCategoryToSlots(
      {0},
      _focus,
      date: DateTime(end.year, end.month, end.day - 400),
    );
    counted.reads = 0;
    expect(provider.getDailyStatistics(start, end), same(daily));
    expect(provider.getStatistics(start, end), stats);
    expect(provider.getEventOccurrenceCounts(start, end), counts);
    expect(counted.reads, 0);
    provider.assignCategoryToSlots({49}, _focus);
    final updated = provider.getDailyStatistics(start, end);
    expect(updated.last.hours, closeTo(1 / 3, 1e-9));
    expect(updated.last.count, 2);
    expect(provider.getEventOccurrenceCounts(start, end)['专注'], 1);
    provider.undo();
    expect(provider.getDailyStatistics(start, end), daily);
    expect(provider.getStatistics(start, end), stats);
    expect(provider.getEventOccurrenceCounts(start, end), counts);
  });

  test('整日清空与撤销刷新趋势缓存', () async {
    final provider = await _createProvider();
    final date = provider.currentDate;
    expect(provider.getDailyStatistics(date, date).single.count, 1);
    provider.clearAll();
    expect(
        provider.getDailyStatistics(date, date).single, (hours: 0.0, count: 0));
    provider.undo();
    expect(provider.getDailyStatistics(date, date).single.hours,
        closeTo(1 / 6, 1e-9));
  });

  test('分类重命名合并标签后趋势的不同事件数更新', () async {
    final provider = await _createProvider();
    final date = provider.currentDate;
    provider.assignCategoryToSlots({49}, _focus);
    expect(provider.getDailyStatistics(date, date).single.count, 2);
    final index = provider.categories.indexWhere((cat) => cat.id == _focus.id);
    provider.updateCategory(index, _focus.copyWith(name: '原始'));
    expect(provider.getDailyStatistics(date, date).single.count, 1);
  });

  test('切换身份清除同一日期范围的趋势、分类和词云缓存', () async {
    final provider = await _createProvider(mobile: true);
    final date = provider.currentDate;
    expect(provider.getDailyStatistics(date, date).single.hours,
        closeTo(1 / 6, 1e-9));
    provider.getStatistics(date, date);
    provider.getEventOccurrenceCounts(date, date);
    await provider.setScheduleUser(DiaryKind.j);
    expect(provider.getDailyStatistics(date, date).single.hours,
        closeTo(1 / 3, 1e-9));
    expect(provider.getStatistics(date, date).keys, ['晶晶记录']);
    expect(provider.getEventOccurrenceCounts(date, date), {'晶晶记录': 1});
  });

  test('日期窗口跨到新一天后重新计算趋势', () async {
    final provider = await _createProvider();
    final date = provider.currentDate;
    final tomorrow = DateTime(date.year, date.month, date.day + 1);
    final original = provider.getDailyStatistics(date, date);
    provider.assignCategoryToSlots({0}, _focus, date: tomorrow);
    expect(provider.getDailyStatistics(date, date), same(original));
    final next = provider.getDailyStatistics(date, tomorrow);
    expect(next, hasLength(2));
    expect(next.last.hours, closeTo(1 / 6, 1e-9));
  });
}
