import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/time_slot_resize.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';

const _focusColor = 0xFF9CB86A;
const _otherColor = 0xFF5B8DEF;

final _focus = Category(
  id: 'focus',
  name: '专注',
  color: const Color(_focusColor),
  updatedAt: 1,
);

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class _SlotWriteStore extends InMemorySharedPreferencesStore {
  // ignore: use_super_parameters
  _SlotWriteStore(Map<String, Object> data) : super.withData(data);

  final List<String> slotWrites = [];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('daily_slots')) slotWrites.add(value as String);
    return super.setValue(valueType, key, value);
  }
}

/// 今天放一个 08:00 的块（索引 48），右侧 08:20（索引 50）放一个别的块。
Future<(TimeProvider, _SlotWriteStore)> _createProvider() async {
  final today = _dateKey(DateTime.now());
  final values = <String, Object>{
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'g',
    'categories': [jsonEncode(_focus.toJson())],
    'daily_slots': jsonEncode({
      today: [
        {'i': 48, 'l': '原始', 'cid': 'focus', 'c': _focusColor, 'ts': 1},
        {'i': 50, 'l': '相邻', 'cid': 'focus', 'c': _otherColor, 'ts': 1},
        {'i': 60, 'l': '日历', 'cid': 'focus', 'c': _focusColor, 'ts': 1, 'fc': true},
      ],
    }),
  };
  SharedPreferences.setMockInitialValues(values);
  final store = _SlotWriteStore({
    for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
  });
  SharedPreferencesStorePlatform.instance = store;
  final provider = TimeProvider(
    identityModePlatformOverride: false,
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
  await provider.onAppBackgrounded();
  await provider.onAppResumed();
  store.slotWrites.clear();
  return (provider, store);
}

TimeSlotResizeRequest _request({
  required TimeProvider provider,
  required int anchorIndex,
  required TimeSlotResizeEdge edge,
  required int targetIndex,
  required int expectedStart,
  required int expectedEnd,
  String label = '原始',
  int color = _focusColor,
}) {
  return TimeSlotResizeRequest(
    date: provider.currentDate,
    anchorIndex: anchorIndex,
    edge: edge,
    targetIndex: targetIndex,
    expectedStart: expectedStart,
    expectedEnd: expectedEnd,
    expectedLabel: label,
    expectedCategoryId: 'focus',
    expectedColor: Color(color),
  );
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

  test('拉长终点：覆盖相邻记录，撤销可完整还原', () async {
    final (provider, _) = await _createProvider();

    final ok = provider.resizeTimeBlock(_request(
      provider: provider,
      anchorIndex: 48,
      edge: TimeSlotResizeEdge.end,
      targetIndex: 50,
      expectedStart: 48,
      expectedEnd: 48,
    ));

    expect(ok, isTrue);
    expect(provider.slots[48].label, '原始');
    expect(provider.slots[49].label, '原始');
    expect(provider.slots[50].label, '原始');
    expect(provider.slots[50].color, const Color(_focusColor));
    expect(provider.canUndo, isTrue);

    provider.undo();
    expect(provider.slots[49].recorded, isFalse);
    expect(provider.slots[50].label, '相邻');
    expect(provider.slots[50].color, const Color(_otherColor));
  });

  test('缩短终点：被裁掉的槽写删除墓碑并落盘', () async {
    final (provider, store) = await _createProvider();
    final dateKey = _dateKey(provider.currentDate);

    // 先拉长成 48..50
    expect(
      provider.resizeTimeBlock(_request(
        provider: provider,
        anchorIndex: 48,
        edge: TimeSlotResizeEdge.end,
        targetIndex: 50,
        expectedStart: 48,
        expectedEnd: 48,
      )),
      isTrue,
    );
    // 再缩回 48..49
    expect(
      provider.resizeTimeBlock(_request(
        provider: provider,
        anchorIndex: 48,
        edge: TimeSlotResizeEdge.end,
        targetIndex: 49,
        expectedStart: 48,
        expectedEnd: 50,
      )),
      isTrue,
    );

    expect(provider.slots[49].label, '原始');
    expect(provider.slots[50].recorded, isFalse);
    expect(provider.slots[50].deletedAt, isNotNull);

    await provider.onAppBackgrounded();
    final written = jsonDecode(store.slotWrites.last) as Map<String, dynamic>;
    final entries = (written[dateKey] as List).cast<Map<String, dynamic>>();
    final tomb = entries.firstWhere((entry) => entry['i'] == 50);
    expect(tomb['del'], isTrue);
    expect(tomb['ts'], isNotNull);
  });

  test('缩短起点：头部写删除墓碑', () async {
    final (provider, _) = await _createProvider();

    expect(
      provider.resizeTimeBlock(_request(
        provider: provider,
        anchorIndex: 48,
        edge: TimeSlotResizeEdge.end,
        targetIndex: 50,
        expectedStart: 48,
        expectedEnd: 48,
      )),
      isTrue,
    );
    expect(
      provider.resizeTimeBlock(_request(
        provider: provider,
        anchorIndex: 48,
        edge: TimeSlotResizeEdge.start,
        targetIndex: 50,
        expectedStart: 48,
        expectedEnd: 50,
      )),
      isTrue,
    );

    expect(provider.slots[48].recorded, isFalse);
    expect(provider.slots[48].deletedAt, isNotNull);
    expect(provider.slots[49].recorded, isFalse);
    expect(provider.slots[50].label, '原始');
  });

  test('至少保留 1 格，不会把块缩没', () async {
    final (provider, _) = await _createProvider();

    // 先拉长成 48..50
    expect(
      provider.resizeTimeBlock(_request(
        provider: provider,
        anchorIndex: 48,
        edge: TimeSlotResizeEdge.end,
        targetIndex: 50,
        expectedStart: 48,
        expectedEnd: 48,
      )),
      isTrue,
    );
    // 把起点拖到块尾之后，会被夹到最后一格
    expect(
      provider.resizeTimeBlock(_request(
        provider: provider,
        anchorIndex: 48,
        edge: TimeSlotResizeEdge.start,
        targetIndex: 100,
        expectedStart: 48,
        expectedEnd: 50,
      )),
      isTrue,
    );

    expect(provider.slots[48].recorded, isFalse);
    expect(provider.slots[49].recorded, isFalse);
    expect(provider.slots[50].label, '原始');
  });

  test('拖拽期间块被改写则拒绝提交', () async {
    final (provider, _) = await _createProvider();
    final request = _request(
      provider: provider,
      anchorIndex: 48,
      edge: TimeSlotResizeEdge.end,
      targetIndex: 50,
      expectedStart: 48,
      expectedEnd: 48,
    );
    final revision = provider.slotsRevision;

    provider.assignCategoryToSlots({48}, _focus, subLabel: '被改过');
    final revisionAfterEdit = provider.slotsRevision;

    expect(provider.resizeTimeBlock(request), isFalse);
    expect(provider.slotsRevision, revisionAfterEdit);
    expect(revisionAfterEdit, isNot(revision));
    expect(provider.slots[48].label, '被改过');
    expect(provider.slots[49].recorded, isFalse);
  });

  test('日历块拒绝调整', () async {
    final (provider, _) = await _createProvider();

    final ok = provider.resizeTimeBlock(_request(
      provider: provider,
      anchorIndex: 60,
      edge: TimeSlotResizeEdge.end,
      targetIndex: 62,
      expectedStart: 60,
      expectedEnd: 60,
      label: '日历',
    ));

    expect(ok, isFalse);
    expect(provider.slots[61].recorded, isFalse);
    expect(provider.canUndo, isFalse);
  });

  test('跨小时的块按整段处理', () async {
    final (provider, _) = await _createProvider();
    // 今天 00:40 起连续 4 格（跨 00 / 01 两行）
    provider.assignCategoryToSlots({4, 5, 6, 7}, _focus, subLabel: '凌晨');

    final ok = provider.resizeTimeBlock(_request(
      provider: provider,
      anchorIndex: 7,
      edge: TimeSlotResizeEdge.end,
      targetIndex: 9,
      expectedStart: 4,
      expectedEnd: 7,
      label: '凌晨',
    ));

    expect(ok, isTrue);
    for (var index = 4; index <= 9; index++) {
      expect(provider.slots[index].label, '凌晨');
    }
  });

  test('一次拖拽只产生一条撤销记录并进入待同步队列', () async {
    final (provider, _) = await _createProvider();
    final dateKey = _dateKey(provider.currentDate);
    final before = provider.slotsRevision;

    expect(
      provider.resizeTimeBlock(_request(
        provider: provider,
        anchorIndex: 48,
        edge: TimeSlotResizeEdge.end,
        targetIndex: 49,
        expectedStart: 48,
        expectedEnd: 48,
      )),
      isTrue,
    );

    expect(provider.slotsRevision, greaterThan(before));
    expect(provider.pendingGiteeSyncDates, contains(dateKey));

    provider.undo();
    expect(provider.canUndo, isFalse);
    expect(provider.slots[49].recorded, isFalse);
  });
}
