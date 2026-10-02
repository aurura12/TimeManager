import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
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

class _CountingPreferencesStore extends InMemorySharedPreferencesStore {
  // ignore: use_super_parameters
  _CountingPreferencesStore(Map<String, Object> data) : super.withData(data);

  final List<String> slotWriteKeys = [];
  final List<String> slotWrites = [];
  final List<String> completedSlotWrites = [];
  Completer<void>? slotWriteGate;
  Completer<void>? pendingWriteGate;
  bool pendingWriteStarted = false;
  int completedPendingWrites = 0;
  bool failNextSlotWrite = false;

  void resetCounters() {
    slotWriteKeys.clear();
    slotWrites.clear();
    completedSlotWrites.clear();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final isSlots = key.endsWith('daily_slots');
    if (isSlots) {
      slotWriteKeys.add(key);
      slotWrites.add(value as String);
      final gate = slotWriteGate;
      if (gate != null) await gate.future;
      if (failNextSlotWrite) {
        failNextSlotWrite = false;
        return false;
      }
    }
    final isPending = key.endsWith('pending_gitee_sync_dates');
    if (isPending && pendingWriteGate != null) {
      pendingWriteStarted = true;
      await pendingWriteGate!.future;
    }
    final result = await super.setValue(valueType, key, value);
    if (isSlots && result) completedSlotWrites.add(value as String);
    if (isPending && result) completedPendingWrites++;
    return result;
  }
}

class _CountingSlot extends TimeSlot {
  _CountingSlot()
      : super(
          hour: 8,
          minute10: 0,
          recorded: true,
          label: '原始',
          categoryId: 'focus',
        );

  int reads = 0;

  @override
  bool get recorded {
    reads++;
    return super.recorded;
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: '保存应在等待期限内完成');
}

Future<(TimeProvider, _CountingPreferencesStore)> _createProvider({
  bool mobile = false,
  Duration localSaveDebounce = const Duration(milliseconds: 250),
}) async {
  final today = _dateKey(DateTime.now());
  final slotsKey = mobile ? 'identity_g_daily_slots' : 'daily_slots';
  final categoriesKey = mobile ? 'identity_g_categories' : 'categories';
  final values = <String, Object>{
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'g',
    categoriesKey: [jsonEncode(_focus.toJson())],
    slotsKey: jsonEncode({
      '2020-01-01': [
        {'i': 0, 'l': '历史', 'cid': 'focus', 'c': 0xFF9CB86A, 'ts': 1},
      ],
      today: [
        {'i': 48, 'l': '原始', 'cid': 'focus', 'c': 0xFF9CB86A, 'ts': 1},
      ],
    }),
    if (mobile) 'identity_j_categories': [jsonEncode(_focus.toJson())],
    if (mobile)
      'identity_j_daily_slots': jsonEncode({
        today: [
          {'i': 60, 'l': '晶晶原始', 'cid': 'focus', 'c': 0xFF9CB86A, 'ts': 1},
        ],
      }),
  };
  SharedPreferences.setMockInitialValues(values);
  final store = _CountingPreferencesStore({
    for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
  });
  SharedPreferencesStorePlatform.instance = store;
  final provider = TimeProvider(
    identityModePlatformOverride: mobile,
    googleCalendarSyncPlatformOverride: false,
    localSaveDebounce: localSaveDebounce,
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
  await provider.onAppBackgrounded();
  await provider.onAppResumed();
  store.resetCounters();
  return (provider, store);
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

  test('十次连续编辑合并成一次保存，历史日期保持不变', () async {
    final (provider, store) = await _createProvider();
    for (var index = 48; index < 58; index++) {
      provider.assignCategoryToSlots({index}, _focus);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(store.slotWrites, isEmpty);
    await _waitUntil(() => store.completedSlotWrites.isNotEmpty);
    expect(store.slotWrites, hasLength(1));
    final root = jsonDecode(store.completedSlotWrites.single) as Map;
    expect(root['2020-01-01'][0]['l'], '历史');
    expect(root[_dateKey(provider.currentDate)], hasLength(10));
  });

  test('切后台立即保存尚未到防抖时间的编辑与同步身份归属', () async {
    final (provider, store) = await _createProvider(
      localSaveDebounce: const Duration(hours: 1),
    );
    provider.assignCategoryToSlots({49}, _focus);
    expect(store.slotWrites, isEmpty);
    await provider.onAppBackgrounded();
    expect(store.completedSlotWrites, hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    final owners = jsonDecode(prefs.getString('pending_gitee_sync_owners')!);
    expect(owners[_dateKey(provider.currentDate)], ['g']);
    final root = jsonDecode(store.completedSlotWrites.single);
    expect(root[_dateKey(provider.currentDate)], hasLength(2));
  });

  test('保存进行中同一天的新编辑不会被旧保存清掉脏标记', () async {
    final (provider, store) = await _createProvider(
      localSaveDebounce: const Duration(hours: 1),
    );
    final gate = Completer<void>();
    store.slotWriteGate = gate;
    provider.assignCategoryToSlots({49}, _focus, subLabel: '第一笔');
    // 这个需要直接落盘的设置同时刷新第一笔编辑，普通编辑仍使用长防抖。
    provider.setCategoryExpandState('focus', false);
    await _waitUntil(() => store.slotWrites.length == 1);
    provider.assignCategoryToSlots({49}, _focus, subLabel: '保存期间的新编辑');
    store.slotWriteGate = null;
    gate.complete();
    await _waitUntil(() => store.completedSlotWrites.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(store.slotWrites, hasLength(1));
    await provider.onAppBackgrounded();
    expect(store.completedSlotWrites, hasLength(2));
    final root = jsonDecode(store.completedSlotWrites.last);
    expect(root[_dateKey(provider.currentDate)].last['l'], '保存期间的新编辑');
  });

  test('保存失败保留脏日期，后续保存可以重试', () async {
    final (provider, store) = await _createProvider();
    store.failNextSlotWrite = true;
    provider.assignCategoryToSlots({49}, _focus);
    await _waitUntil(() => store.slotWrites.length == 1);
    expect(store.completedSlotWrites, isEmpty);
    await provider.onAppBackgrounded();
    expect(store.completedSlotWrites, hasLength(1));
    final root = jsonDecode(store.completedSlotWrites.single);
    expect(root[_dateKey(provider.currentDate)], hasLength(2));
  });

  test('待同步队列落盘期间新增日期，下一次保存仍写出新增日期与身份归属', () async {
    final (provider, store) = await _createProvider(
      localSaveDebounce: const Duration(hours: 1),
    );
    final gate = Completer<void>();
    store.pendingWriteGate = gate;
    final completedBefore = store.completedPendingWrites;
    provider.assignCategoryToSlots({49}, _focus);
    provider.setCategoryExpandState('focus', false);
    await _waitUntil(() => store.pendingWriteStarted);
    final otherDate = provider.currentDate.subtract(const Duration(days: 365));
    provider.assignCategoryToSlots({49}, _focus, date: otherDate);
    store.pendingWriteGate = null;
    gate.complete();
    await _waitUntil(() => store.completedPendingWrites > completedBefore);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await provider.onAppBackgrounded();
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('pending_gitee_sync_dates'),
      containsAll([_dateKey(provider.currentDate), _dateKey(otherDate)]),
    );
    final owners = jsonDecode(prefs.getString('pending_gitee_sync_owners')!);
    expect(owners[_dateKey(otherDate)], ['g']);
    final root = jsonDecode(store.completedSlotWrites.last);
    expect(root[_dateKey(otherDate)].single['l'], '专注');
  });

  test('移动端切身份先保存旧身份编辑，另一身份的数据保持独立', () async {
    final (provider, store) = await _createProvider(
      mobile: true,
      localSaveDebounce: const Duration(hours: 1),
    );
    provider.assignCategoryToSlots({49}, _focus, subLabel: '乖乖新编辑');
    await provider.setScheduleUser(DiaryKind.j);
    final prefs = await SharedPreferences.getInstance();
    final oldRoot = jsonDecode(prefs.getString('identity_g_daily_slots')!);
    final newRoot = jsonDecode(prefs.getString('identity_j_daily_slots')!);
    expect(oldRoot[_dateKey(provider.currentDate)].last['l'], '乖乖新编辑');
    expect(newRoot[_dateKey(provider.currentDate)].single['l'], '晶晶原始');
    expect(store.slotWriteKeys, ['flutter.identity_g_daily_slots']);
  });

  test('覆盖拉取失败后仍保存进入覆盖前等待中的编辑', () async {
    final (provider, store) = await _createProvider(
      localSaveDebounce: const Duration(hours: 1),
    );
    provider.assignCategoryToSlots({49}, _focus, subLabel: '覆盖前编辑');
    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    await _waitUntil(() => store.completedSlotWrites.isNotEmpty);
    final root = jsonDecode(store.completedSlotWrites.last);
    expect(root[_dateKey(provider.currentDate)].last['l'], '覆盖前编辑');
  });

  test('桌面切身份在等待普通编辑落盘时已锁定身份，覆盖拉取不能插入', () async {
    final (provider, store) = await _createProvider(
      localSaveDebounce: const Duration(hours: 1),
    );
    final gate = Completer<void>();
    store.slotWriteGate = gate;
    provider.assignCategoryToSlots({49}, _focus, subLabel: '切身份前编辑');
    final setter = provider.setScheduleUser(DiaryKind.j);
    await _waitUntil(() => store.slotWrites.isNotEmpty);
    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    expect(provider.lastScheduleOverwriteFailure, contains('身份切换进行中'));
    final revision = provider.slotsRevision;
    provider.assignCategoryToSlots({50}, _focus);
    expect(provider.slotsRevision, revision);
    store.slotWriteGate = null;
    gate.complete();
    await setter;
    expect(provider.scheduleUser, DiaryKind.j);
    final root = jsonDecode(store.completedSlotWrites.single);
    expect(root[_dateKey(provider.currentDate)].last['l'], '切身份前编辑');
  });

  test('统计在内存编辑后立即更新，不等待防抖保存', () async {
    final (provider, store) = await _createProvider(
      localSaveDebounce: const Duration(hours: 1),
    );
    final date = provider.currentDate;
    expect(provider.getStatistics(date, date)['原始'], closeTo(1 / 6, 1e-9));
    expect(provider.getEventOccurrenceCounts(date, date)['原始'], 1);
    provider.assignCategoryToSlots({49}, _focus);
    expect(provider.getStatistics(date, date)['专注'], closeTo(1 / 6, 1e-9));
    expect(provider.getEventOccurrenceCounts(date, date)['专注'], 1);
    expect(store.slotWrites, isEmpty);
  });

  test('范围外日期的编辑与落盘保留已有统计及连续块缓存', () async {
    final (provider, _) = await _createProvider(
      localSaveDebounce: const Duration(hours: 1),
    );
    final date = provider.currentDate;
    final counted = _CountingSlot();
    provider.slotsForDate(date)[48] = counted;
    provider.getStatistics(date, date);
    provider.getEventOccurrenceCounts(date, date);
    expect(counted.reads, greaterThan(0));
    provider.assignCategoryToSlots(
      {49},
      _focus,
      date: date.subtract(const Duration(days: 365)),
    );
    await provider.onAppBackgrounded();
    counted.reads = 0;
    expect(provider.getStatistics(date, date)['原始'], closeTo(1 / 6, 1e-9));
    expect(provider.getEventOccurrenceCounts(date, date)['原始'], 1);
    expect(counted.reads, 0, reason: '范围外修改后应直接命中缓存，不重新访问槽位');
  });
}
