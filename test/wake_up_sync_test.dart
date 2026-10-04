import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/models/wake_up_document.dart';
import 'package:time_manager/models/wake_up_record.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/providers/wake_up_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/sync_center_service.dart';
import 'package:time_manager/services/wake_up_local_store.dart';
import 'package:time_manager/services/wake_up_sync_dependencies.dart';

class _MemoryStore extends WakeUpLocalStore {
  final documents = <DiaryKind, WakeUpDocument>{};
  int writes = 0;
  bool failSave = false;
  Completer<void>? loadGate;

  @override
  Future<WakeUpDocument> load(DiaryKind kind) async {
    await loadGate?.future;
    return documents[kind] ?? WakeUpDocument();
  }

  @override
  Future<void> save(DiaryKind kind, WakeUpDocument document) async {
    if (failSave) throw StateError('disk error');
    writes++;
    documents[kind] = document;
  }
}

class _Remote {
  final bodies = <String, String>{};
  final revisions = <String, int>{};
  final reads = <String>[];
  final writes = <String>[];
  String? token = 'test-token';
  bool failPull = false;
  bool failPush = false;
  Completer<void>? readGate;
  Completer<void>? readEntered;
  Future<void> Function(String code, WakeUpDocument outgoing)? beforePush;

  String? sha(String code) =>
      bodies.containsKey(code) ? '${revisions[code]}' : null;
  void set(String code, WakeUpDocument document) {
    bodies[code] = document.encode();
    revisions[code] = (revisions[code] ?? 0) + 1;
  }

  WakeUpDocument document(String code) =>
      WakeUpDocument.decode(bodies[code]!, allowLegacy: false);

  WakeUpSyncDependencies get dependencies => WakeUpSyncDependencies(
        loadToken: () async => token,
        pull: ({required token, required userCode}) async {
          reads.add(userCode);
          final body = bodies[userCode];
          final version = sha(userCode);
          if (readEntered != null && !readEntered!.isCompleted) {
            readEntered!.complete();
          }
          await readGate?.future;
          if (failPull) {
            return (
              success: false,
              notFound: false,
              content: null,
              sha: null,
              error: 'offline'
            );
          }
          return (
            success: body != null,
            notFound: body == null,
            content: body,
            sha: version,
            error: null
          );
        },
        push: (
            {required token,
            required userCode,
            required content,
            required commitMessage,
            String? expectedSha,
            bool expectNotFound = false}) async {
          writes.add(userCode);
          final outgoing = WakeUpDocument.decode(content, allowLegacy: false);
          await beforePush?.call(userCode, outgoing);
          if (failPush) {
            return (success: false, conflict: false, error: 'offline');
          }
          if (expectedSha != sha(userCode) ||
              (expectNotFound && bodies.containsKey(userCode))) {
            return (success: false, conflict: true, error: 'sha mismatch');
          }
          set(userCode, outgoing);
          return (success: true, conflict: false, error: null);
        },
      );
}

WakeUpDocument _document(DateTime time, int updatedAt) {
  final record = WakeUpRecord(time, updatedAt: updatedAt);
  return WakeUpDocument(records: {record.dateKey: record});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var now = DateTime(2026, 10, 4, 10);

  setUp(() async {
    now = DateTime(2026, 10, 4, 10);
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => null);
    await AppIdentityService.load();
  });
  tearDown(AppIdentityService.resetForTesting);

  Future<WakeUpProvider> device(
    _Remote remote, {
    WakeUpLocalStore? store,
    bool autoSync = false,
    SyncStatusCoordinator? coordinator,
  }) async {
    final provider = WakeUpProvider(
      store: store ?? _MemoryStore(),
      clock: () => now,
      syncDependencies: remote.dependencies,
      autoSync: autoSync,
      statusCoordinator: coordinator,
    );
    addTearDown(provider.dispose);
    await provider.ready;
    return provider;
  }

  test('手机上传、电脑拉取并修改、手机再拉取，两端一致且无空提交', () async {
    final remote = _Remote();
    final phone = await device(remote);
    final desktopStore = _MemoryStore();
    final desktop = await device(remote, store: desktopStore);
    await phone.record(DateTime(2026, 10, 4, 7, 30), expectedKind: DiaryKind.j);
    expect((await phone.synchronize()).succeeded, isTrue);
    expect(remote.writes, ['j']);
    expect(jsonDecode(remote.bodies['j']!).containsKey('pendingSync'), isFalse);
    expect((await desktop.synchronize()).succeeded, isTrue);
    expect(desktop.recordFor(now)!.timeLabel, '07:30');
    now = DateTime(2026, 10, 4, 11);
    await desktop.record(DateTime(2026, 10, 4, 7, 15),
        expectedKind: DiaryKind.j);
    await desktop.synchronize();
    await phone.synchronize();
    expect(phone.recordFor(now)!.timeLabel, '07:15');
    expect(phone.hasPendingSync, isFalse);
    final count = desktopStore.writes;
    await desktop.synchronize();
    expect(remote.writes, ['j', 'j']);
    expect(desktopStore.writes, count);
    expect(remote.document('j').records.values.single.timeLabel, '07:15');
  });

  test('删除通过墓碑传播，旧设备不能恢复记录，之后可以重新记录', () async {
    final remote = _Remote();
    final phone = await device(remote);
    final desktop = await device(remote);
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    await phone.synchronize();
    await desktop.synchronize();
    now = DateTime(2026, 10, 4, 11);
    await desktop.remove(now, expectedKind: DiaryKind.j);
    await desktop.synchronize();
    await phone.synchronize();
    expect(phone.recordFor(now), isNull);
    expect(remote.document('j').records, isEmpty);
    expect(remote.document('j').deletedDates, contains('2026-10-04'));
    now = DateTime(2026, 10, 4, 12);
    await phone.record(DateTime(2026, 10, 4, 7, 20), expectedKind: DiaryKind.j);
    await phone.synchronize();
    await desktop.synchronize();
    expect(desktop.recordFor(now)!.timeLabel, '07:20');
  });

  test('离线待上传标记随记录持久化，重启后可继续同步', () async {
    final remote = _Remote()..token = null;
    final store = _MemoryStore();
    final first = await device(remote, store: store);
    await first.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    final offline = await first.synchronize();
    expect(offline.status, SyncModuleStatus.offline);
    expect(offline.pendingUploadCount, 1);
    expect(store.documents[DiaryKind.j]!.pendingSync, isTrue);
    final restarted = await device(remote, store: store);
    expect(restarted.hasPendingSync, isTrue);
    remote.token = 'test-token';
    await restarted.synchronize();
    expect(restarted.hasPendingSync, isFalse);
    expect(store.documents[DiaryKind.j]!.pendingSync, isFalse);
    expect(remote.document('j').records.values.single.timeLabel, '07:00');
  });

  test('同一次上传中又修改时间，不会把新版本待同步标记清掉', () async {
    final remote = _Remote();
    final phone = await device(remote);
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    remote.beforePush = (code, outgoing) async {
      remote.beforePush = null;
      await phone.record(DateTime(2026, 10, 4, 7, 45),
          expectedKind: DiaryKind.j);
    };
    final result = await phone.synchronize();
    expect(result.status, SyncModuleStatus.pending);
    expect(phone.recordFor(now)!.timeLabel, '07:45');
    expect(phone.hasPendingSync, isTrue);
    expect(remote.document('j').records.values.single.timeLabel, '07:00');
    await phone.synchronize();
    expect(remote.document('j').records.values.single.timeLabel, '07:45');
    expect(phone.hasPendingSync, isFalse);
  });

  test('SHA 冲突重新拉取合并，两端不同日期的编辑都保留', () async {
    final remote = _Remote();
    final phone = await device(remote);
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    remote.beforePush = (code, outgoing) async {
      remote.beforePush = null;
      remote.set(code, _document(DateTime(2026, 10, 3, 8), 100));
    };
    final result = await phone.synchronize();
    expect(result.succeeded, isTrue);
    expect(remote.reads, ['j', 'j']);
    expect(remote.writes, ['j', 'j']);
    expect(remote.document('j').records.keys,
        containsAll(['2026-10-03', '2026-10-04']));
    expect(phone.recordFor(DateTime(2026, 10, 3))!.timeLabel, '08:00');
  });

  test('持续版本冲突最多尝试三次，保留待上传数据供之后重试', () async {
    final remote = _Remote();
    final phone = await device(remote);
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    remote.beforePush = (code, outgoing) async {
      remote.set(code, _document(DateTime(2026, 10, 3, 8), 100));
    };
    expect((await phone.synchronize()).status, SyncModuleStatus.conflict);
    expect(remote.reads, hasLength(3));
    expect(remote.writes, hasLength(3));
    expect(phone.hasPendingSync, isTrue);
    expect(phone.recordFor(now)!.timeLabel, '07:00');
    remote.beforePush = null;
    expect((await phone.synchronize()).succeeded, isTrue);
    expect(remote.document('j').records, hasLength(2));
  });

  test('远端读取失败、内容损坏或本地合并落盘失败都不上传覆盖', () async {
    final remote = _Remote()..failPull = true;
    final store = _MemoryStore();
    final phone = await device(remote, store: store);
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    expect((await phone.synchronize()).status, SyncModuleStatus.failed);
    remote.failPull = false;
    remote.bodies['j'] = '{invalid';
    remote.revisions['j'] = 1;
    expect((await phone.synchronize()).status, SyncModuleStatus.failed);
    expect(remote.writes, isEmpty);
    expect(phone.recordFor(now)!.timeLabel, '07:00');
    expect(phone.hasPendingSync, isTrue);
    remote.set('j', _document(DateTime(2026, 10, 3, 8), 100));
    store.failSave = true;
    expect((await phone.synchronize()).status, SyncModuleStatus.failed);
    expect(remote.writes, isEmpty);
    expect(phone.recordFor(DateTime(2026, 10, 3)), isNull);
    store.failSave = false;
    expect((await phone.synchronize()).succeeded, isTrue);
    expect(remote.document('j').records, hasLength(2));
  });

  test('本机旧版起床记录迁移后加入首次上传，不覆盖远端新修改', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        WakeUpLocalStore.keyFor(DiaryKind.j),
        jsonEncode({
          'version': 1,
          'records': [
            {'date': '2026-10-03', 'hour': 7, 'minute': 0},
            {'date': '2026-10-04', 'hour': 8, 'minute': 0},
          ],
        }));
    final remote = _Remote()
      ..set('j', _document(DateTime(2026, 10, 4, 7, 30), 100));
    final phone = await device(remote, store: WakeUpLocalStore());
    expect(phone.hasPendingSync, isTrue);
    await phone.synchronize();
    expect(phone.recordFor(now)!.timeLabel, '07:30');
    expect(remote.document('j').records, hasLength(2));
    final persisted = await WakeUpLocalStore().load(DiaryKind.j);
    expect(persisted.pendingSync, isFalse);
    expect(persisted.records.values.every((record) => record.updatedAt > 0),
        isTrue);
  });

  test('同步请求期间切身份，旧响应不混入新身份，待上传归属仍正确', () async {
    final remote = _Remote()
      ..set('j', _document(DateTime(2026, 10, 3, 8), 100))
      ..readGate = Completer<void>()
      ..readEntered = Completer<void>();
    final store = _MemoryStore();
    final phone = await device(remote, store: store);
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    final oldSync = phone.synchronize();
    await remote.readEntered!.future;
    AppIdentityService.adoptManualKind(DiaryKind.g);
    await phone.reload();
    await phone.record(DateTime(2026, 10, 4, 9), expectedKind: DiaryKind.g);
    remote.readGate!.complete();
    expect((await oldSync).status, SyncModuleStatus.skipped);
    await phone.synchronize();
    expect(remote.writes, ['g']);
    expect(phone.recordFor(now)!.timeLabel, '09:00');
    expect(phone.recordFor(DateTime(2026, 10, 3)), isNull);
    expect(store.documents[DiaryKind.j]!.pendingSync, isTrue);
    expect(
        store.documents[DiaryKind.j]!.records.values.single.timeLabel, '07:00');
    expect(store.documents[DiaryKind.g]!.pendingSync, isFalse);
  });

  test('相同时间戳合并结果与设备顺序无关，删除优先', () {
    final first = _document(DateTime(2026, 10, 4, 7), 100);
    final second = _document(DateTime(2026, 10, 4, 8), 100);
    expect(WakeUpDocument.merge(first, second).encode(),
        WakeUpDocument.merge(second, first).encode());
    final deleted = WakeUpDocument(deletedDates: {'2026-10-04': 100});
    expect(WakeUpDocument.merge(first, deleted).records, isEmpty);
    expect(WakeUpDocument.merge(deleted, first).records, isEmpty);
  });

  test('同步中心复用同一入口，自动同步和重试并发时只记一次失败', () async {
    final coordinator = SyncStatusCoordinator(
        store: InMemorySyncStatusStore(), loadIdentityBeforeState: false);
    addTearDown(coordinator.dispose);
    final remote = _Remote()
      ..failPull = true
      ..readGate = Completer<void>()
      ..readEntered = Completer<void>();
    final phone = await device(remote, coordinator: coordinator);
    final time = TimeProvider(
      identityModePlatformOverride: true,
      googleCalendarSyncPlatformOverride: false,
      saveDataOverride: () async => true,
      scheduleSyncDependencies: ScheduleSyncDependencies(
        loadToken: () async => null,
        listPaths: ({required token, required userCode}) async =>
            ScheduleGiteeListWithShaResult.error('offline'),
        pullDay: (
                {required token, required dateKey, required userCode}) async =>
            ScheduleGiteePullResult.error('offline'),
      ),
    );
    addTearDown(time.dispose);
    await time.waitForSyncReady();
    final center = SyncCenterController.forProvider(time,
        wakeUpProvider: phone, coordinator: coordinator);
    addTearDown(center.dispose);
    await center.initialize();
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    final automatic = phone.synchronize();
    await remote.readEntered!.future;
    final retry = center.retry(SyncModule.wakeUp);
    await Future<void>.delayed(Duration.zero);
    remote.readGate!.complete();
    await automatic;
    await retry;
    final state = center.stateFor(SyncModule.wakeUp);
    expect(state.status, SyncModuleStatus.failed);
    expect(state.failureCount, 1);
    expect(state.pendingUploadCount, 1);
    expect(remote.reads, ['j']);
    remote.failPull = false;
    await center.retry(SyncModule.wakeUp);
    expect(center.stateFor(SyncModule.wakeUp).status, SyncModuleStatus.success);
    expect(center.stateFor(SyncModule.wakeUp).lastSuccessAt, isNotNull);
    expect(center.stateFor(SyncModule.wakeUp).pendingUploadCount, 0);
  });

  testWidgets('未打开目标页也会自动同步，编辑防抖、后台停表、回前台拉取', (tester) async {
    final remote = _Remote();
    final phone = await device(remote, autoSync: true);
    await phone.synchronize();
    final initialReads = remote.reads.length;
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    await tester.pump(const Duration(seconds: 2));
    expect(remote.reads.length, initialReads);
    await phone.record(DateTime(2026, 10, 4, 7, 15), expectedKind: DiaryKind.j);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(remote.document('j').records.values.single.timeLabel, '07:15');
    final beforePoll = remote.reads.length;
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(remote.reads.length, beforePoll + 1);
    final count = remote.reads.length;
    await phone.onAppBackgrounded();
    await tester.pump(const Duration(minutes: 5));
    expect(remote.reads.length, count);
    now = DateTime(2026, 10, 4, 11);
    remote.set('j',
        _document(DateTime(2026, 10, 4, 6, 45), now.millisecondsSinceEpoch));
    phone.onAppResumed();
    await tester.pumpAndSettle();
    expect(phone.recordFor(now)!.timeLabel, '06:45');
    await phone.onAppBackgrounded();
  });

  testWidgets('切后台遇到慢拉取，收尾仅补推一次待同步记录', (tester) async {
    final remote = _Remote();
    final phone = await device(remote, autoSync: true);
    await phone.synchronize();
    await phone.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    final count = remote.reads.length;
    remote.readGate = Completer<void>();
    remote.readEntered = Completer<void>();
    final foregroundSync = phone.synchronize();
    await remote.readEntered!.future;
    await phone.onAppBackgrounded();
    remote.readGate!.complete();
    expect((await foregroundSync).status, SyncModuleStatus.skipped);
    await tester.pumpAndSettle();
    expect(remote.reads.length, count + 2);
    expect(remote.writes, ['j']);
    expect(phone.hasPendingSync, isFalse);
    expect(remote.document('j').records.values.single.timeLabel, '07:00');
    await tester.pump(const Duration(minutes: 5));
    expect(remote.reads.length, count + 2);
  });

  testWidgets('在后台完成初始化不会重装自动同步定时器，回前台恢复', (tester) async {
    final remote = _Remote();
    final store = _MemoryStore()..loadGate = Completer<void>();
    store.documents[DiaryKind.j] =
        _document(DateTime(2026, 10, 4, 7), 100).withPending(true);
    final phone = WakeUpProvider(
      store: store,
      clock: () => now,
      syncDependencies: remote.dependencies,
    );
    addTearDown(phone.dispose);
    await phone.onAppBackgrounded();
    store.loadGate!.complete();
    await phone.ready;
    await tester.pump(const Duration(minutes: 5));
    expect(remote.reads, isEmpty);
    expect(phone.hasPendingSync, isTrue);
    phone.onAppResumed();
    await tester.pumpAndSettle();
    expect(remote.reads, ['j']);
    expect(remote.writes, ['j']);
    expect(phone.hasPendingSync, isFalse);
    await phone.onAppBackgrounded();
  });
}
