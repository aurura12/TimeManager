import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/schedule_sync_manifest_store.dart';

class _RemoteState {
  final Map<String, String> remoteContents = {};
  final Map<String, String> remoteShas = {};
  final List<String> listRequests = [];
  final List<String> pullRequests = [];
  final List<String> pushRequests = [];
  int _pushSeq = 0;

  /// 非空时每次拉正文都会等待它，用来制造"刷新进行中"的窗口。
  Completer<void>? pullGate;

  /// 非空时每次推送都会等待它（拉取不受影响），用来制造"推送进行中"的窗口。
  Completer<void>? pushGate;

  /// 让正文拉取/推送失败，用来验证失败路径不会污染同步基线。
  bool failPull = false;
  bool failPush = false;

  /// 让列表接口返回过期的 SHA（正文接口仍返回真实 SHA），
  /// 用来验证基线记录的是"正文实际对应的版本"。
  bool listReturnsStaleSha = false;

  void setRemote(String code, String dateKey, String content, String sha) {
    remoteContents['$code/$dateKey'] = content;
    remoteShas['$code/$dateKey'] = sha;
  }

  void clearCounters() {
    listRequests.clear();
    pullRequests.clear();
  }
}

ScheduleSyncDependencies _fakeDependencies(_RemoteState state) {
  return ScheduleSyncDependencies(
    loadToken: () async => 'fake-token',
    listPaths: ({required token, required userCode}) async {
      state.listRequests.add(userCode);
      final map = <String, String>{};
      state.remoteShas.forEach((key, sha) {
        final slash = key.indexOf('/');
        final code = key.substring(0, slash);
        final dateKey = key.substring(slash + 1);
        if (code == userCode) {
          map['schedule/$code/$dateKey.json'] =
              state.listReturnsStaleSha ? '$sha-stale' : sha;
        }
      });
      return ScheduleGiteeListWithShaResult.success(map);
    },
    pullDay: ({required token, required dateKey, required userCode}) async {
      state.pullRequests.add('$userCode/$dateKey');
      final gate = state.pullGate;
      if (gate != null) await gate.future;
      if (state.failPull) {
        return ScheduleGiteePullResult.error('fake pull failure');
      }
      final key = '$userCode/$dateKey';
      final content = state.remoteContents[key];
      if (content == null) return ScheduleGiteePullResult.notFound();
      return ScheduleGiteePullResult.success(
        content,
        state.remoteShas[key] ?? 'sha-$key',
      );
    },
    pushDay: ({
      required token,
      required dateKey,
      required userCode,
      required content,
      required commitMessage,
      String? expectedSha,
      bool expectNotFound = false,
    }) async {
      final key = '$userCode/$dateKey';
      state.pushRequests.add(key);
      final pushGate = state.pushGate;
      if (pushGate != null) await pushGate.future;
      if (state.failPush) {
        return ScheduleGiteePushResult.error('fake push failure');
      }
      // 真实远端写入后会换一个新的 blob SHA，并把它回传给调用方。
      final newSha = 'pushed-${state._pushSeq++}';
      state.remoteContents[key] = content;
      state.remoteShas[key] = newSha;
      return ScheduleGiteePushResult.success(created: false, sha: newSha);
    },
    pullGoogleDay: (date) async => const [],
    pushGoogleDay: (slots, date) async => true,
  );
}

Future<TimeProvider> _createProvider(
  _RemoteState state, {
  required bool mobile,
  Duration? autoRefreshInterval,
  Duration scheduleGiteeDebounce = const Duration(seconds: 3),
  /// true 时保留磁盘上的数据，用来模拟"重启后新建 Provider"。
  bool preservePreferences = false,
  /// false 时不等待初始化完成就返回，用来模拟"初始化还没跑完就切后台"。
  bool waitForInit = true,
  /// 额外的初始偏好，用来模拟旧版本/备份导入留下的数据。
  Map<String, Object> extraPreferences = const {},
}) async {
  if (!preservePreferences) {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: DiaryKind.g.code,
      ...extraPreferences,
    });
  }
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  final provider = TimeProvider(
    identityModePlatformOverride: mobile,
    googleCalendarSyncPlatformOverride: false,
    scheduleSyncDependencies: _fakeDependencies(state),
    scheduleAutoRefreshInterval: autoRefreshInterval,
    scheduleGiteeDebounce: scheduleGiteeDebounce,
  );
  if (!waitForInit) return provider;
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return provider;
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  test('远端与本地一致时不再下载正文，远端变化才重新下载', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: false);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.setRemote(
      'g',
      '2026-09-05',
      '{"updated_at":1000,"slots":[{"i":10,"l":"前一晚","c":1,"ts":1000}]}',
      'sha-05',
    );
    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    state.setRemote(
      'g',
      '2026-09-07',
      '{"updated_at":1000,"slots":[{"i":20,"l":"次日","c":1,"ts":1000}]}',
      'sha-07',
    );

    // 首次刷新：manifest 尚未建立，可见的三天都要下载正文。
    expect(await provider.refreshSchedulesFromRemoteInBackground(), isTrue);
    expect(state.listRequests.length, 1, reason: '每次刷新只发一次远端列表请求');
    expect(
      state.pullRequests.toSet(),
      {'g/2026-09-05', 'g/2026-09-06', 'g/2026-09-07'},
    );
    expect(provider.getSlotsForDate('2026-09-06')?[60].label, '远端当天');

    // 第二次刷新：远端 SHA 与本地指纹都没变 → 0 次正文下载、0 次通知。
    state.clearCounters();
    var notifications = 0;
    void listener() => notifications++;
    provider.addListener(listener);
    expect(await provider.refreshSchedulesFromRemoteInBackground(), isFalse);
    provider.removeListener(listener);
    expect(state.listRequests.length, 1, reason: '仍然只发一次列表请求');
    expect(state.pullRequests, isEmpty, reason: '完全一致时不应下载正文');
    expect(notifications, 0, reason: '没有任何变化就不应该触碰 UI');

    // 只改其中一天：只有那天会重新下载正文。
    state.clearCounters();
    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":3000,"slots":[{"i":60,"l":"改过的当天","c":1,"ts":3000}]}',
      'sha-06-new',
    );
    expect(await provider.refreshSchedulesFromRemoteInBackground(), isTrue);
    expect(state.pullRequests, ['g/2026-09-06']);
    expect(provider.getSlotsForDate('2026-09-06')?[60].label, '改过的当天');
  });

  test('推送成功后回写基线，下一次刷新不会重新下载这一天', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: true,
      scheduleGiteeDebounce: const Duration(milliseconds: 20),
    );
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    // 先刷新一次，让本地拿到远端内容并把基线建起来。
    expect(await provider.refreshSchedulesFromRemoteInBackground(), isTrue);
    expect(provider.getSlotsForDate('2026-09-06')?[60].label, '远端当天');

    // 本地改一笔：取消该槽位的记录 → 生成删除墓碑，触发防抖自动推送。
    provider.toggleSlot(60);
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    expect(state.pushRequests, isNotEmpty, reason: '本地改动应该被自动推送');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    state.clearCounters();

    // 推送时已经把新 SHA 写回基线，所以下一次刷新应当直接跳过这一天。
    await provider.refreshSchedulesFromRemoteInBackground();
    expect(state.listRequests.length, 1, reason: '仍然只发一次列表请求');
    expect(
      state.pullRequests,
      isEmpty,
      reason: '刚推上去的那天不应被重新下载（基线已记录新 SHA）',
    );
  });

  test('正文拉取失败不会被记成已对账，下一轮会重试', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    state.failPull = true;

    expect(await provider.refreshSchedulesFromRemoteInBackground(), isFalse);
    expect(state.pullRequests, ['g/2026-09-06']);
    expect(provider.getSlotsForDate('2026-09-06')?[60].label, isNot('远端当天'));

    var manifest = await ScheduleSyncManifestStore.load('g');
    expect(
      manifest?.localFingerprintByDate.containsKey('2026-09-06'),
      isFalse,
      reason: '正文没读到就不能建立该天的本地指纹基线',
    );
    expect(manifest?.pendingKinds['2026-09-06'], 'error');

    // 远端内容没变，但因为失败过，下一轮必须重新检查并重试。
    state.clearCounters();
    await provider.refreshSchedulesFromRemoteInBackground();
    expect(state.pullRequests, ['g/2026-09-06'], reason: '失败后下一轮必须重试');

    // 恢复成功后正文合并进本地，error 标记被清掉。
    state.failPull = false;
    state.clearCounters();
    expect(await provider.refreshSchedulesFromRemoteInBackground(), isTrue);
    expect(provider.getSlotsForDate('2026-09-06')?[60].label, '远端当天');
    manifest = await ScheduleSyncManifestStore.load('g');
    expect(manifest?.pendingKinds.containsKey('2026-09-06'), isFalse);
    expect(manifest?.localFingerprintByDate.containsKey('2026-09-06'), isTrue);
  });

  test('未检查的日期不会被写进同步基线', () async {
    final state = _RemoteState();
    // 手机只可见当前一天，方便让某一天"不可见"。
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    // 切日会主动拉一次，本地因此有 09-06 的数据，但轮询基线还没建立。
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == '远端当天',
    );
    provider.goToDate(DateTime(2026, 9, 10));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    await provider.refreshSchedulesFromRemoteInBackground();

    final manifest = await ScheduleSyncManifestStore.load('g');
    expect(manifest?.localFingerprintByDate.containsKey('2026-09-10'), isTrue);
    expect(
      manifest?.localFingerprintByDate.containsKey('2026-09-06'),
      isFalse,
      reason: '不可见的日期这一轮没有对过账，不能提前写成已验证',
    );
  });

  test('远程视图下切后台也会停掉轮询定时器', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      autoRefreshInterval: const Duration(milliseconds: 40),
    );
    addTearDown(provider.dispose);

    await _waitUntil(() => provider.hasScheduleAutoRefreshTimer);
    // 轮询可能正在跑，此时远程视图切换会被忽略，所以要重试到生效为止。
    for (var i = 0; i < 100 && !provider.isRemoteViewEnabled; i++) {
      await provider.toggleRemoteScheduleView();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(provider.isRemoteViewEnabled, isTrue);
    expect(provider.hasScheduleAutoRefreshTimer, isTrue);

    await provider.onAppBackgrounded();
    expect(
      provider.hasScheduleAutoRefreshTimer,
      isFalse,
      reason: '远程视图下切后台会提前返回，定时器仍必须被停掉',
    );
  });

  test('身份切换后轮询定时器会被重新装上', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      autoRefreshInterval: const Duration(milliseconds: 40),
    );
    addTearDown(provider.dispose);

    await _waitUntil(() => provider.hasScheduleAutoRefreshTimer);
    await provider.setScheduleUser(DiaryKind.j);
    await _waitUntil(() => provider.hasScheduleAutoRefreshTimer);
    expect(
      provider.hasScheduleAutoRefreshTimer,
      isTrue,
      reason: '身份切换会停表，切成功后必须重新装上，否则桌面端再也不轮询',
    );
  });

  test('前台定时器周期性刷新，切后台后停止', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      autoRefreshInterval: const Duration(milliseconds: 40),
    );
    addTearDown(provider.dispose);

    await _waitUntil(() => state.listRequests.length >= 2);
    expect(state.listRequests.length, greaterThanOrEqualTo(2));

    await provider.onAppBackgrounded();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    state.clearCounters();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(state.listRequests, isEmpty, reason: '切后台后不应继续轮询');
  });

  test('手机没有定时器，但回到前台会立即检查一次', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    await provider.onAppResumed();
    expect(state.listRequests.length, 1, reason: '回前台立即做一次检查');

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(state.listRequests.length, 1, reason: '手机端不应创建轮询定时器');
  });

  test('刷新进行中时覆盖拉取会被拒绝', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: false);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    state.pullGate = Completer<void>();

    final refresh = provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pullRequests.isNotEmpty);

    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    expect(provider.lastScheduleOverwriteFailure, contains('已有日程同步任务'));

    state.pullGate!.complete();
    state.pullGate = null;
    await refresh;
  });

  test('重启后持久化的待推送日程会在下一轮轮询里自愈', () async {
    final state = _RemoteState();
    final first = await _createProvider(state, mobile: false);
    addTearDown(first.dispose);
    first.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    await first.refreshSchedulesFromRemoteInBackground();
    expect(first.getSlotsForDate('2026-09-06')?[60].label, '远端当天');

    // 本地改一笔但推送失败：待同步日期会被持久化，但只存在 _pendingSyncState 里。
    state.failPush = true;
    first.toggleSlot(60);
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(first.pendingGiteeSyncDates, contains('2026-09-06'));

    // 模拟重启：保留磁盘数据，新建一个 Provider（内存里的待推送队列是空的）。
    AppIdentityService.resetForTesting();
    state.failPush = false;
    state.clearCounters();
    final second = await _createProvider(
      state,
      mobile: false,
      preservePreferences: true,
    );
    addTearDown(second.dispose);
    second.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    await second.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    expect(
      state.pushRequests,
      isNotEmpty,
      reason: '重启后持久化的待推送日期必须在轮询里补推，而不是永远挂着',
    );
  });

  test('推送期间又改了同一天时，基线不会误记为已对齐', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: true,
      scheduleGiteeDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    await provider.refreshSchedulesFromRemoteInBackground();
    final fingerprintBefore =
        (await ScheduleSyncManifestStore.load('g'))?.localFingerprintByDate[
            '2026-09-06'];
    expect(fingerprintBefore, isNotNull);

    // 让推送卡在"先拉远端"这一步
    state.pullGate = Completer<void>();
    final push = provider.syncScheduleToGitee(dateKey: '2026-09-06');
    await _waitUntil(() => state.pullRequests.isNotEmpty);

    // 推送进行中，用户又改了同一天 → 编辑版本号变化
    provider.toggleSlot(60);
    state.pullGate!.complete();
    state.pullGate = null;
    await push;

    final manifestAfterPush = await ScheduleSyncManifestStore.load('g');
    expect(
      manifestAfterPush?.localFingerprintByDate['2026-09-06'],
      fingerprintBefore,
      reason: '推送期间本地又变了，指纹必须保持旧值，否则基线会说"已对齐"',
    );
    expect(
      manifestAfterPush?.remoteShaByDate['2026-09-06'],
      isNot('sha-06'),
      reason: '远端 SHA 是事实，推送成功后照常回写',
    );
  });

  test('远端重新提交等价内容时不落盘也不通知', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    expect(await provider.refreshSchedulesFromRemoteInBackground(), isTrue);

    // 远端换了提交（SHA 变了）但槽位内容完全等价
    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":9999,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06-recommitted',
    );
    state.clearCounters();
    var notifications = 0;
    void listener() => notifications++;
    provider.addListener(listener);
    final changed = await provider.refreshSchedulesFromRemoteInBackground();
    provider.removeListener(listener);

    expect(state.pullRequests, ['g/2026-09-06'], reason: 'SHA 变了要下载正文');
    expect(changed, isFalse, reason: '内容等价，不算本地改动');
    expect(notifications, 0, reason: '内容等价就不该通知 UI');
  });

  test('覆盖拉取成功后重建基线，下一轮不会重复下载', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);
    expect(provider.getSlotsForDate('2026-09-06')?[60].label, '远端当天');

    state.clearCounters();
    expect(await provider.refreshSchedulesFromRemoteInBackground(), isFalse);
    expect(state.listRequests.length, 1);
    expect(
      state.pullRequests,
      isEmpty,
      reason: '覆盖后本地等于远端，基线已重建，不该再下载正文',
    );
  });

  test('轮询进行中时全量同步/全量拉取都会被拒绝', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: false);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    state.pullGate = Completer<void>();

    final refresh = provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pullRequests.isNotEmpty);

    final syncResult = await provider.syncAllSchedulesToGitee();
    expect(syncResult?.message, contains('已有日程同步任务'));

    state.listRequests.clear();
    await provider.pullAllSchedulesFromGitee();
    expect(
      state.listRequests,
      isEmpty,
      reason: '轮询进行中时全量拉取必须直接返回，不能并发读写槽位',
    );

    state.pullGate!.complete();
    state.pullGate = null;
    await refresh;
  });

  test('初始化在切后台之后完成时不会装回轮询定时器', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      autoRefreshInterval: const Duration(milliseconds: 40),
      waitForInit: false,
    );
    addTearDown(provider.dispose);

    // 初始化还没跑完就切后台
    await provider.onAppBackgrounded();
    await _waitUntil(() => provider.isInitialLoadFinished);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(
      provider.hasScheduleAutoRefreshTimer,
      isFalse,
      reason: '切后台之后才跑完的初始化不能把定时器装回来',
    );
    expect(state.listRequests, isEmpty);

    // 回到前台后必须能正常恢复轮询
    await provider.onAppResumed();
    expect(provider.hasScheduleAutoRefreshTimer, isTrue);
  });

  test('列表 SHA 与正文 SHA 不一致时，基线记录正文的 SHA', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    state.listReturnsStaleSha = true;
    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    expect(await provider.refreshSchedulesFromRemoteInBackground(), isTrue);

    final manifest = await ScheduleSyncManifestStore.load('g');
    expect(
      manifest?.remoteShaByDate['2026-09-06'],
      'sha-06',
      reason: '必须记录正文实际对应的版本，而不是可能已过期的列表 SHA',
    );
  });

  test('远端文件被删掉后会被重新建回来', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == '远端当天',
    );
    // 先跑一轮，让基线知道这一天原本在远端存在
    await provider.refreshSchedulesFromRemoteInBackground();
    expect(
      (await ScheduleSyncManifestStore.load('g'))
          ?.remoteDates
          .contains('2026-09-06'),
      isTrue,
    );

    // 远端文件被外部删掉
    state.remoteContents.clear();
    state.remoteShas.clear();
    state.clearCounters();

    await provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pushRequests.isNotEmpty);

    expect(
      state.pushRequests,
      contains('g/2026-09-06'),
      reason: '基线里原本存在过、现在消失 → 应该重新建回去',
    );
    expect(
      state.remoteShas.containsKey('g/2026-09-06'),
      isTrue,
      reason: '远端文件应该被重新创建',
    );
    expect(
      provider.getSlotsForDate('2026-09-06')?[60].label,
      '远端当天',
      reason: '本地数据不能被远端文件的消失清掉',
    );
  });

  test('远端从未存在过某天时不会主动创建（避免批量复制本地数据）', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == '远端当天',
    );

    // 远端清空，且此前没有建立过基线（模拟"刚切到另一个身份、该身份下还没有文件"）
    state.remoteContents.clear();
    state.remoteShas.clear();
    state.clearCounters();

    await provider.refreshSchedulesFromRemoteInBackground();

    final manifest = await ScheduleSyncManifestStore.load('g');
    expect(state.pushRequests, isEmpty, reason: '从未存在过的远端文件不该被轮询创建');
    expect(provider.pendingGiteeSyncDates, isEmpty);
    expect(manifest?.pendingKinds.containsKey('2026-09-06'), isFalse);
    expect(provider.getSlotsForDate('2026-09-06')?[60].label, '远端当天');
  });

  test('轮询进行中切后台后不再继续下载后续日期，也不补推', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: false);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state.clearCounters();

    for (final dateKey in ['2026-09-05', '2026-09-06', '2026-09-07']) {
      state.setRemote(
        'g',
        dateKey,
        '{"updated_at":2000,"slots":[{"i":60,"l":"远端-$dateKey","c":1,"ts":2000}]}',
        'sha-$dateKey',
      );
    }
    state.pullGate = Completer<void>();
    final refresh = provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pullRequests.isNotEmpty);

    // 轮询进行中切后台
    await provider.onAppBackgrounded();
    state.pullGate!.complete();
    state.pullGate = null;
    await refresh;
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(
      state.pullRequests.length,
      1,
      reason: '切后台后不应继续下载后续日期',
    );
    expect(state.pushRequests, isEmpty, reason: '后台收尾不得补推');
  });

  test('同步中心发现待上传日期时不会因为待同步集合不可变而失败', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: true);
    addTearDown(provider.dispose);

    // 让本地拿到内容（切日主动拉取），随后远端没有这一天的文件 → 检查应判为 upload
    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == '远端当天',
    );
    state.remoteContents.clear();
    state.remoteShas.clear();

    final result = await provider.checkScheduleSyncState();

    expect(result.status, SyncModuleStatus.pending);
    expect(result.message, contains('待同步'));
    expect(
      provider.pendingGiteeSyncDates,
      contains('2026-09-06'),
      reason: '待上传日期必须真的进入待同步队列',
    );
  });

  test('桌面端切身份后不会把旧身份的待推送日期推到新身份', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      scheduleGiteeDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == '远端当天',
    );

    // g 身份下改一笔但推送失败 → 待推送队列归属 g
    state.failPush = true;
    provider.toggleSlot(60);
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(provider.pendingGiteeSyncDates, contains('2026-09-06'));

    // 切到 j 身份
    await provider.setScheduleUser(DiaryKind.j);
    state.failPush = false;
    state.clearCounters();

    await provider.refreshSchedulesFromRemoteInBackground();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      state.pushRequests.where((key) => key.startsWith('j/')),
      isEmpty,
      reason: 'g 身份失败的待推送日期不能在新身份下被自动补推',
    );
    expect(
      state.remoteShas.keys.any((key) => key.startsWith('j/')),
      isFalse,
      reason: '不能往新身份的命名空间写入旧身份的数据',
    );
    expect(
      provider.pendingGiteeSyncDates,
      contains('2026-09-06'),
      reason: '待推送日期也不能就这样丢掉',
    );
  });

  test('待同步日期归属未知时不会自动补推（fail-closed）', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      // 旧版本/备份导入留下的待同步日期：只有日期，没有归属记录
      extraPreferences: const {
        'pending_gitee_sync_dates': ['2026-09-06'],
      },
    );
    addTearDown(provider.dispose);

    expect(provider.pendingGiteeSyncDates, contains('2026-09-06'));
    state.clearCounters();

    await provider.refreshSchedulesFromRemoteInBackground();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      state.pushRequests,
      isEmpty,
      reason: '归属未知的日期不能在当前身份下被自动补推',
    );
    expect(
      provider.pendingGiteeSyncDates,
      contains('2026-09-06'),
      reason: '也不能被丢掉，手动同步仍应带上它',
    );
  });

  test('混合身份的待同步队列只自动补推当前身份自己那部分', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      scheduleGiteeDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"g当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == 'g当天',
    );

    // g 身份下改 09-06 但推送失败
    state.failPush = true;
    provider.toggleSlot(60);
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 切到 j，并在 j 身份下改 09-05（同样推送失败）
    await provider.setScheduleUser(DiaryKind.j);
    state.setRemote(
      'j',
      '2026-09-05',
      '{"updated_at":2000,"slots":[{"i":60,"l":"j前一天","c":1,"ts":2000}]}',
      'sha-05-j',
    );
    provider.goToDate(DateTime(2026, 9, 5));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-05')?[60].label == 'j前一天',
    );
    provider.toggleSlot(60);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(provider.pendingGiteeSyncDates, containsAll(['2026-09-06', '2026-09-05']));

    state.failPush = false;
    state.clearCounters();

    await provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      state.pushRequests,
      contains('j/2026-09-05'),
      reason: '当前身份自己的待推送日期要正常自愈',
    );
    expect(
      state.pushRequests,
      isNot(contains('j/2026-09-06')),
      reason: '属于 g 身份的 09-06 不能被推到 j 的命名空间',
    );
    expect(provider.pendingGiteeSyncDates, contains('2026-09-06'));
  });

  test('同一天在两个身份下都有失败推送时，各自都还能补推', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      scheduleGiteeDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"g当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == 'g当天',
    );

    // g 身份改同一天但推送失败
    state.failPush = true;
    provider.toggleSlot(60);
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 切到 j，再改同一天，同样推送失败
    await provider.setScheduleUser(DiaryKind.j);
    provider.toggleSlot(60);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(provider.pendingGiteeSyncDates, contains('2026-09-06'));

    // j 补推成功后，这天的待推送状态不能跟着被清掉（g 还欠着）
    state.failPush = false;
    state.clearCounters();
    await provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(
      () => state.pushRequests.any((key) => key.startsWith('j/')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      provider.pendingGiteeSyncDates,
      contains('2026-09-06'),
      reason: 'j 推送成功不能把 g 的待推送一起清掉',
    );

    // 切回 g：这一天仍然要能自动补推
    await provider.setScheduleUser(DiaryKind.g);
    state.clearCounters();
    await provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pushRequests.contains('g/2026-09-06'));

    expect(
      state.pushRequests,
      contains('g/2026-09-06'),
      reason: '回到 g 身份后这一天的待推送必须还在，能自动补上',
    );
  });

  test('桌面三列窗口滚动时补拉新露出的日期', () async {
    final state = _RemoteState();
    final provider = await _createProvider(state, mobile: false);
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    state.pullGate = Completer<void>();
    final refresh = provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pullRequests.isNotEmpty);

    // 轮询进行中前进一天：可见窗口 05/06/07 → 06/07/08，当前日 07 仍在旧窗口里
    provider.nextDay();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    state.clearCounters();

    state.pullGate!.complete();
    state.pullGate = null;
    await refresh;
    await _waitUntil(() => state.pullRequests.contains('g/2026-09-08'));

    expect(
      state.pullRequests,
      contains('g/2026-09-08'),
      reason: '新露出的 09-08 必须在轮询收尾补拉，而不是等下一轮 60 秒',
    );
    expect(
      state.pullRequests,
      isNot(contains('g/2026-09-07')),
      reason: '旧日期本轮已经处理过，不该被整个窗口重拉一遍',
    );
  });

  test('轮询进行中切后台时，本次修改仍然会被补推一次', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: true,
      scheduleGiteeDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == '远端当天',
    );

    // 本地改一笔但推送失败 → 留在待推送队列
    state.failPush = true;
    provider.toggleSlot(60);
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(provider.pendingGiteeSyncDates, contains('2026-09-06'));

    // 让轮询卡在下载正文，并在卡住期间切后台
    state.failPush = false;
    state.remoteShas['g/2026-09-06'] = 'sha-06-v2';
    state.pullGate = Completer<void>();
    state.clearCounters();
    unawaited(provider.refreshSchedulesFromRemoteInBackground());
    await _waitUntil(() => state.pullRequests.isNotEmpty);

    final backgrounded = provider.onAppBackgrounded();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    state.pullGate!.complete();
    state.pullGate = null;
    await backgrounded;

    expect(
      state.pushRequests,
      isNotEmpty,
      reason: '切后台那一次有意补推要等轮询释放锁后执行，不能直接丢掉',
    );
  });

  test('轮询超过 5 秒仍未结束时，切后台的补推由轮询收尾补做', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: true,
      scheduleGiteeDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"远端当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == '远端当天',
    );

    state.failPush = true;
    provider.toggleSlot(60);
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(provider.pendingGiteeSyncDates, contains('2026-09-06'));

    // 轮询卡住超过 onAppBackgrounded 的 5 秒等待窗口
    state.failPush = false;
    state.remoteShas['g/2026-09-06'] = 'sha-06-v2';
    state.pullGate = Completer<void>();
    state.clearCounters();
    unawaited(provider.refreshSchedulesFromRemoteInBackground());
    await _waitUntil(() => state.pullRequests.isNotEmpty);

    final backgrounded = provider.onAppBackgrounded();
    await Future<void>.delayed(const Duration(milliseconds: 5200));
    state.pullGate!.complete();
    state.pullGate = null;
    await backgrounded;
    await _waitUntil(() => state.pushRequests.isNotEmpty);

    expect(
      state.pushRequests,
      isNotEmpty,
      reason: '超出等待窗口的补推不能丢，应由轮询收尾补做一次',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('共享队列里已属于别的身份时，当前身份发现远端删失仍会重建', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      // 这一天已经在共享队列里，但归属是另一个身份。
      // 归属在生产代码里是以 JSON 字符串存的，这里必须一致。
      extraPreferences: const {
        'pending_gitee_sync_dates': ['2026-09-06'],
        'pending_gitee_sync_owners': '{"2026-09-06":["j"]}',
      },
    );
    addTearDown(provider.dispose);

    // g 的远端原本有过这一天 → 先建立 g 的基线
    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"g当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    provider.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => provider.getSlotsForDate('2026-09-06')?[60].label == 'g当天',
    );
    await provider.refreshSchedulesFromRemoteInBackground();

    // g 的远端文件被删掉
    state.remoteContents.remove('g/2026-09-06');
    state.remoteShas.remove('g/2026-09-06');
    state.clearCounters();

    await provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pushRequests.isNotEmpty);

    expect(
      state.pushRequests,
      contains('g/2026-09-06'),
      reason: '这一天虽然已属于 j，g 发现自己文件被删时也必须加入归属并重建',
    );
  });
  test('备份会带上待同步日期的身份归属', () async {
    final state = _RemoteState();
    var sourceDisposed = false;
    final source = await _createProvider(
      state,
      mobile: false,
      scheduleGiteeDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(() {
      if (!sourceDisposed) source.dispose();
    });

    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"g当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    source.goToDate(DateTime(2026, 9, 6));
    await _waitUntil(
      () => source.getSlotsForDate('2026-09-06')?[60].label == 'g当天',
    );
    state.failPush = true;
    source.toggleSlot(60);
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(source.pendingGiteeSyncDates, contains('2026-09-06'));

    final backupJson = source.exportBackupJson();
    // 导出契约：归属必须真的写进备份（只导出日期是不够的，
    // 恢复后这些日期会变成"归属未知"、被 fail-closed 永久跳过）。
    expect(
      (json.decode(backupJson) as Map)['pendingGiteeSyncOwners'],
      {
        '2026-09-06': ['g'],
      },
    );
    source.dispose();
    sourceDisposed = true;

    // 导入到一个全新实例（会重置 SharedPreferences）
    state.failPush = false;
    state.clearCounters();
    final restored = await _createProvider(state, mobile: false);
    addTearDown(restored.dispose);
    await restored.importBackupJson(backupJson);

    state.clearCounters();
    await restored.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pushRequests.isNotEmpty);

    expect(
      state.pushRequests,
      contains('g/2026-09-06'),
      reason: '备份里的身份归属必须恢复，否则这些日期会被 fail-closed 永久跳过',
    );
  });

  test('轮询收尾先补推，补推没完不会并发补拉新露出的日期', () async {
    final state = _RemoteState();
    final provider = await _createProvider(
      state,
      mobile: false,
      extraPreferences: const {
        'pending_gitee_sync_dates': ['2026-09-06'],
        'pending_gitee_sync_owners': '{"2026-09-06":["g"]}',
      },
    );
    addTearDown(provider.dispose);

    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // 可见日期必须有远端文件，轮询才会真的去下载正文（否则它会瞬间跑完）
    state.setRemote(
      'g',
      '2026-09-06',
      '{"updated_at":2000,"slots":[{"i":60,"l":"g当天","c":1,"ts":2000}]}',
      'sha-06',
    );
    state.setRemote(
      'g',
      '2026-09-08',
      '{"updated_at":2000,"slots":[{"i":60,"l":"g次日","c":1,"ts":2000}]}',
      'sha-08',
    );

    // 卡住轮询自身的正文下载，期间把可见窗口前滚一天
    state.pullGate = Completer<void>();
    final refresh = provider.refreshSchedulesFromRemoteInBackground();
    await _waitUntil(() => state.pullRequests.isNotEmpty);
    provider.nextDay();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    state.clearCounters();

    // 放开轮询的下载，同时卡住收尾的补推
    state.pushGate = Completer<void>();
    state.pullGate!.complete();
    state.pullGate = null;
    await _waitUntil(() => state.pushRequests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      state.pullRequests,
      isNot(contains('g/2026-09-08')),
      reason: '补推还没结束，收尾不该已经并发去拉新露出的日期',
    );

    state.pushGate!.complete();
    state.pushGate = null;
    await _waitUntil(() => state.pullRequests.contains('g/2026-09-08'));

    expect(state.pullRequests, contains('g/2026-09-08'));
    await refresh;
  });
  test('ScheduleSyncManifest 相等性用于跳过重复写盘', () {
    const a = ScheduleSyncManifest(
      remoteDates: {'2026-09-06'},
      remoteShaByDate: {'2026-09-06': 'sha'},
      localFingerprintByDate: {'2026-09-06': 'fp'},
      pendingKinds: {'2026-09-07': 'upload'},
    );
    const b = ScheduleSyncManifest(
      remoteDates: {'2026-09-06'},
      remoteShaByDate: {'2026-09-06': 'sha'},
      localFingerprintByDate: {'2026-09-06': 'fp'},
      pendingKinds: {'2026-09-07': 'upload'},
    );
    const differentSha = ScheduleSyncManifest(
      remoteDates: {'2026-09-06'},
      remoteShaByDate: {'2026-09-06': 'other'},
      localFingerprintByDate: {'2026-09-06': 'fp'},
      pendingKinds: {'2026-09-07': 'upload'},
    );

    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(differentSha));
  });
}
