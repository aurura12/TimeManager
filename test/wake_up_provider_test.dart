import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/wake_up_document.dart';
import 'package:time_manager/models/wake_up_record.dart';
import 'package:time_manager/providers/wake_up_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/wake_up_local_store.dart';

class _ControlledStore extends WakeUpLocalStore {
  final data = <DiaryKind, WakeUpDocument>{};
  Completer<void>? saveGate;
  Completer<WakeUpDocument>? loadGate;
  bool failSave = false;

  @override
  Future<WakeUpDocument> load(DiaryKind kind) async {
    if (kind == DiaryKind.j && loadGate != null) return loadGate!.future;
    return data[kind] ?? WakeUpDocument();
  }

  @override
  Future<void> save(DiaryKind kind, WakeUpDocument document) async {
    await saveGate?.future;
    if (failSave) throw StateError('无法保存起床记录，请重试');
    data[kind] = document;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final today = DateTime(2026, 10, 4, 10, 15);

  setUp(() async {
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    await AppIdentityService.load();
  });
  tearDown(AppIdentityService.resetForTesting);

  Future<WakeUpProvider> makeProvider({WakeUpLocalStore? store}) async {
    final provider = WakeUpProvider(store: store, clock: () => today);
    addTearDown(provider.dispose);
    await provider.ready;
    return provider;
  }

  test('记录和修改按天保存，重新加载仍能计算已起床时长', () async {
    final provider = await makeProvider();
    await provider.record(DateTime(2026, 10, 4, 7, 30, 45),
        expectedKind: DiaryKind.j);
    final restored = await makeProvider();
    expect(restored.recordFor(today)!.timeLabel, '07:30');
    expect(restored.recordFor(today)!.elapsedAt(today),
        const Duration(hours: 2, minutes: 45));

    await provider.record(DateTime(2026, 10, 4, 7, 15),
        expectedKind: DiaryKind.j);
    await restored.reload();
    expect(restored.recordFor(today)!.timeLabel, '07:15');
    final prefs = await SharedPreferences.getInstance();
    final document =
        jsonDecode(prefs.getString(WakeUpLocalStore.keyFor(DiaryKind.j))!);
    expect(document['records'], hasLength(1));
    expect(prefs.containsKey(WakeUpLocalStore.keyFor(DiaryKind.g)), isFalse);
  });

  test('重复快速记录不会覆盖起床时间，未来时间被拒绝', () async {
    final provider = await makeProvider();
    await provider.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    await provider.record(today,
        expectedKind: DiaryKind.j, replaceExisting: false);
    await expectLater(
        provider.record(DateTime(2026, 10, 4, 11), expectedKind: DiaryKind.j),
        throwsArgumentError);
    expect(provider.recordFor(today)!.timeLabel, '07:00');
    expect(provider.recordFor(today)!.elapsedAt(DateTime(2026, 10, 4, 6)),
        Duration.zero);
  });

  test('近七天平均只计实际记录，跨月和跨日仍按自然日取值', () async {
    final provider = await makeProvider();
    for (final time in [
      DateTime(2026, 9, 27, 12), // 七天窗口以外。
      DateTime(2026, 9, 28, 7),
      DateTime(2026, 9, 30, 8),
      DateTime(2026, 10, 4, 9),
    ]) {
      await provider.record(time, expectedKind: DiaryKind.j);
    }
    expect(provider.recentRecords(today), hasLength(3));
    expect(provider.averageMinute(today), 8 * 60);
    final tomorrow = DateTime(2026, 10, 5);
    expect(provider.recordFor(tomorrow), isNull);
    expect(provider.recordFor(DateTime(2026, 10, 4))!.timeLabel, '09:00');
    expect(provider.averageMinute(tomorrow), 8 * 60 + 30);
    await provider.remove(DateTime(2026, 9, 30), expectedKind: DiaryKind.j);
    final restored = await makeProvider();
    expect(restored.recordFor(DateTime(2026, 9, 30)), isNull);
    expect(restored.averageMinute(today), 8 * 60);
  });

  test('历史查询覆盖全部记录，日期范围含首尾并忽略时分秒', () async {
    final provider = await makeProvider();
    for (final time in [
      DateTime(2025, 12, 31, 7),
      DateTime(2026, 1, 1, 8),
      DateTime(2026, 9, 4, 9),
      DateTime(2026, 10, 4, 10),
    ]) {
      await provider.record(time, expectedKind: DiaryKind.j);
    }
    expect(provider.recordsInRange().map((r) => r.dateKey), [
      '2026-10-04',
      '2026-09-04',
      '2026-01-01',
      '2025-12-31',
    ]);
    expect(
        provider
            .recordsInRange(
                start: DateTime(2025, 12, 31, 23, 59),
                end: DateTime(2026, 1, 1))
            .map((r) => r.timeLabel),
        ['08:00', '07:00']);
    expect(provider.recordsInRange(end: DateTime(2025, 12, 30)), isEmpty);
    expect(() => provider.recordsInRange().clear(), throwsUnsupportedError);
    await provider.remove(DateTime(2025, 12, 31), expectedKind: DiaryKind.j);
    expect(provider.recordsInRange(), hasLength(3));
  });

  test('不同身份的记录隔离，旧身份打开的编辑不能写入新身份', () async {
    final provider = await makeProvider();
    await provider.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    AppIdentityService.adoptManualKind(DiaryKind.g);
    await provider.reload();
    expect(provider.kind, DiaryKind.g);
    expect(provider.recordFor(today), isNull);
    expect(provider.recordsInRange(), isEmpty);
    await expectLater(
        provider.record(DateTime(2026, 10, 4, 8), expectedKind: DiaryKind.j),
        throwsStateError);
    await provider.record(DateTime(2026, 10, 4, 8), expectedKind: DiaryKind.g);
    AppIdentityService.adoptManualKind(DiaryKind.j);
    await provider.reload();
    expect(provider.recordFor(today)!.timeLabel, '07:00');
    AppIdentityService.adoptManualKind(DiaryKind.g);
    await provider.reload();
    expect(provider.recordFor(today)!.timeLabel, '08:00');
  });

  test('保存期间切换再切回身份，等待保存后加载且不污染其他身份', () async {
    final store = _ControlledStore()..saveGate = Completer<void>();
    final provider = await makeProvider(store: store);
    final saving =
        provider.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    expect(provider.isSaving, isTrue);
    AppIdentityService.adoptManualKind(DiaryKind.g);
    final loadingOther = provider.reload();
    expect(provider.recordFor(today), isNull);
    AppIdentityService.adoptManualKind(DiaryKind.j);
    final loadingOriginal = provider.reload();
    store.saveGate!.complete();
    await saving;
    await loadingOther;
    await loadingOriginal;
    expect(provider.recordFor(today)!.timeLabel, '07:00');
    expect(store.data[DiaryKind.g], isNull);
    expect(provider.canRecord, isTrue);
  });

  test('旧身份的慢读取完成后不能覆盖新身份', () async {
    final store = _ControlledStore()..loadGate = Completer<WakeUpDocument>();
    final provider = WakeUpProvider(store: store, clock: () => today);
    addTearDown(provider.dispose);
    AppIdentityService.adoptManualKind(DiaryKind.g);
    await provider.reload();
    final old = WakeUpRecord(DateTime(2026, 10, 4, 7));
    store.loadGate!.complete(WakeUpDocument(records: {old.dateKey: old}));
    await provider.ready;
    expect(provider.kind, DiaryKind.g);
    expect(provider.recordFor(today), isNull);
  });

  test('保存失败保留原值，删除失败也不丢记录', () async {
    final store = _ControlledStore();
    final provider = await makeProvider(store: store);
    await provider.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    store.failSave = true;
    await expectLater(
        provider.record(DateTime(2026, 10, 4, 8), expectedKind: DiaryKind.j),
        throwsStateError);
    await expectLater(
        provider.remove(today, expectedKind: DiaryKind.j), throwsStateError);
    expect(provider.recordFor(today)!.timeLabel, '07:00');
    expect(provider.isSaving, isFalse);
  });

  test('损坏的数据拒绝覆盖，修复后可以重试加载', () async {
    final prefs = await SharedPreferences.getInstance();
    final key = WakeUpLocalStore.keyFor(DiaryKind.j);
    final invalid = jsonEncode({
      'version': 1,
      'records': [
        {'date': '2026-02-30', 'hour': 7, 'minute': 0}
      ],
    });
    await prefs.setString(key, invalid);
    final provider = await makeProvider();
    expect(provider.loadError, isNotNull);
    expect(provider.canRecord, isFalse);
    await expectLater(
        provider.record(today, expectedKind: DiaryKind.j), throwsStateError);
    expect(prefs.getString(key), invalid);
    await prefs.remove(key);
    await provider.reload();
    expect(provider.loadError, isNull);
    expect(provider.canRecord, isTrue);
  });

  test('未选身份不能记录，也不会写入未绑定身份的偏好', () async {
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues(
        {AppIdentityService.modeKey: 'manual'});
    final provider = await makeProvider();
    expect(provider.isLoaded, isTrue);
    expect(provider.kind, isNull);
    expect(provider.canRecord, isFalse);
    await expectLater(
        provider.record(today, expectedKind: DiaryKind.j), throwsStateError);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((key) => key.contains('wake_up')), isEmpty);
  });

  test('身份初始化失败可以显示错误并重试，不会一直停在读取中', () async {
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
      AppIdentityService.legacySyncKey: 'invalid',
    });
    final provider = await makeProvider();
    expect(provider.loadError, isNotNull);
    expect(provider.canRecord, isFalse);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppIdentityService.legacySyncKey);
    await provider.reload();
    expect(provider.kind, DiaryKind.j);
    expect(provider.loadError, isNull);
    expect(provider.canRecord, isTrue);
  });
}
