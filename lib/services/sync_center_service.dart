import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sync_center_state.dart';
import '../models/travel_record.dart';
import '../providers/time_provider.dart';
import 'check_in_sync_service.dart';
import 'diary_gitee_service.dart';
import 'diary_local_store.dart';
import 'diary_search_service.dart';
import 'travel_gitee_service.dart';
import 'travel_local_store.dart';

typedef SyncCenterOperation = Future<SyncOperationResult> Function();

/// 读取宿主当前实时同步状态。
///
/// 返回值是部分映射：只有确实能提供可靠实时状态的模块才应返回。控制器
/// 会结合控制器构造函数的 `authoritativeLiveStateModules` 参数决定哪些模块
/// 可以覆盖同步中心状态；未提供可靠 reader 的模块继续使用最近一次业务操作
/// 的结果，避免用默认的 0 清掉待同步照片或其他失败信息。
typedef SyncCenterLiveStateReader = Map<SyncModule, SyncModuleState> Function();

/// 同步中心状态的本地存储。只保存状态和时间，不保存任何凭据。
abstract interface class SyncCenterStateStore {
  Future<Map<SyncModule, SyncModuleState>> load();

  Future<void> save(Iterable<SyncModuleState> states);
}

class SharedPreferencesSyncCenterStateStore implements SyncCenterStateStore {
  static const String storageKey = 'sync_center_state_v1';

  @override
  Future<Map<SyncModule, SyncModuleState>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.trim().isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};

      final result = <SyncModule, SyncModuleState>{};
      for (final module in SyncModule.values) {
        final value = decoded[module.storageKey];
        if (value is Map) {
          result[module] = SyncModuleState.fromJson(
            module,
            Map<String, dynamic>.from(value),
          );
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> save(Iterable<SyncModuleState> states) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        for (final state in states) state.module.storageKey: state.toJson(),
      };
      await prefs.setString(storageKey, jsonEncode(payload));
    } catch (_) {
      // 状态展示失败不能影响业务数据同步。
    }
  }
}

/// 用于单元测试或宿主暂时不需要持久化时的内存状态存储。
class InMemorySyncCenterStateStore implements SyncCenterStateStore {
  InMemorySyncCenterStateStore([
    Map<SyncModule, SyncModuleState>? initial,
  ]) : _states = {...?initial};

  Map<SyncModule, SyncModuleState> _states;

  @override
  Future<Map<SyncModule, SyncModuleState>> load() async => {..._states};

  @override
  Future<void> save(Iterable<SyncModuleState> states) async {
    _states = {for (final state in states) state.module: state};
  }
}

/// 业务同步入口的集合。同步中心只编排，不复制各模块的远端协议。
class SyncCenterOperations {
  SyncCenterOperations(
      {required Map<SyncModule, SyncCenterOperation> operations})
      : _operations = Map.unmodifiable(operations);

  final Map<SyncModule, SyncCenterOperation> _operations;

  Future<SyncOperationResult> run(SyncModule module) async {
    final operation = _operations[module];
    if (operation == null) {
      return SyncOperationResult.failed('${module.label}暂不支持同步');
    }
    return operation();
  }

  factory SyncCenterOperations.production(TimeProvider provider) {
    final checkIn = CheckInSyncService();
    return SyncCenterOperations(
      operations: {
        for (final module in [
          SyncModule.schedule,
          SyncModule.categories,
          SyncModule.targets,
          SyncModule.googleCalendar,
        ])
          module: () => provider.syncModuleForCenter(module),
        SyncModule.diary: _syncDiary,
        SyncModule.travel: _syncTravel,
        SyncModule.checkIn: () => _syncCheckIn(checkIn),
      },
    );
  }

  static Future<SyncOperationResult> _syncDiary() async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.trim().isEmpty) {
      return const SyncOperationResult.offline('日记远端未连接，本地草稿会保留');
    }

    // 先确认远端目录可读，再复用已有的增量索引刷新入口；不在同步中心
    // 复制日记编辑器的路径选择、冲突确认和写入逻辑。
    final listing = await DiaryGiteeService.listDiaryPathsWithSha(
      token: token,
    );
    if (!listing.success) {
      return SyncOperationResult.failed(
        '日记同步失败：${listing.error ?? '远端列表不可用'}',
      );
    }
    await DiarySearchService.refreshCache(token);
    return SyncOperationResult.success(
      message: '日记索引已刷新（${listing.pathShaMap.length} 个文件）',
    );
  }

  static Future<SyncOperationResult> _syncTravel() async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.trim().isEmpty) {
      return const SyncOperationResult.offline('出行远端未连接，本地记录会保留');
    }

    final localRaw = await TravelLocalStore.loadDraft();
    TravelRecordsDocument local;
    if (localRaw == null || localRaw.trim().isEmpty) {
      local = const TravelRecordsDocument(records: []);
    } else {
      try {
        local = TravelRecordsDocument.fromMarkdown(localRaw);
      } catch (error) {
        return SyncOperationResult.failed('本地出行记录格式异常：$error');
      }
    }

    final pull = await TravelGiteeService.pullFile(
      token: token,
      path: TravelRecordsDocument.filePath,
    );
    if (!pull.success && !pull.notFound) {
      return SyncOperationResult.failed(
        '出行同步失败：${pull.error ?? '远端记录不可用'}',
      );
    }

    if (pull.notFound) {
      if (local.records.isEmpty && local.deletedDateKeys.isEmpty) {
        return const SyncOperationResult.success(message: '暂无出行记录需要同步');
      }
      final push = await TravelGiteeService.pushFile(
        token: token,
        path: TravelRecordsDocument.filePath,
        content: local.toMarkdown(),
        commitMessage: 'travel: sync',
        expectNotFound: true,
      );
      return push.success
          ? const SyncOperationResult.success(message: '出行记录已同步')
          : SyncOperationResult.failed(
              '出行同步失败：${push.error ?? '远端写入失败'}',
            );
    }

    final remote = TravelRecordsDocument.fromMarkdown(pull.content!);
    final remoteOnly = remote.recordDateKeys
        .difference(local.recordDateKeys)
        .difference(local.deletedDateKeys);
    final conflicts = local.conflictingDateKeys(remote);
    if (remoteOnly.isNotEmpty) {
      return SyncOperationResult.conflict(
        '远端有本地没有的出行记录，请先在出行页面拉取确认',
        conflictCount: remoteOnly.length,
        details: remoteOnly.take(10).toList(growable: false),
      );
    }
    if (conflicts.isNotEmpty) {
      return SyncOperationResult.conflict(
        '本地与远端出行记录存在内容冲突，请先在出行页面确认',
        conflictCount: conflicts.length,
        details: conflicts.take(10).toList(growable: false),
      );
    }

    final outgoing = local.preparePush(remote);
    final push = await TravelGiteeService.pushFile(
      token: token,
      path: TravelRecordsDocument.filePath,
      content: outgoing.toMarkdown(),
      commitMessage: 'travel: sync',
      expectedSha: pull.sha,
    );
    if (!push.success) {
      return SyncOperationResult.failed(
        '出行同步失败：${push.error ?? '远端写入失败'}',
      );
    }
    await TravelLocalStore.saveDraft(outgoing.toMarkdown());
    return const SyncOperationResult.success(message: '出行记录已同步');
  }

  static Future<SyncOperationResult> _syncCheckIn(
    CheckInSyncService sync,
  ) async {
    await sync.initialize(silent: true);
    final result = await sync.pushToGitHub();
    if (result.success) {
      return SyncOperationResult.success(
        message: result.warning ?? '打卡数据已同步',
        pendingUploadCount: result.warning == null ? 0 : 1,
      );
    }
    final message = result.error ?? '打卡同步失败';
    if (message.contains('未配置') || message.contains('身份')) {
      return SyncOperationResult.offline(message);
    }
    return SyncOperationResult.failed(message);
  }
}

/// 同步中心的状态编排器。所有“全部重试”操作按模块串行执行。
class SyncCenterController extends ChangeNotifier {
  SyncCenterController({
    required SyncCenterOperations operations,
    SyncCenterStateStore? store,
    SyncCenterLiveStateReader? liveStateReader,
    Set<SyncModule>? authoritativeLiveStateModules,
  })  : _operations = operations,
        _store = store ?? SharedPreferencesSyncCenterStateStore(),
        _liveStateReader = liveStateReader,
        _authoritativeLiveStateModules = authoritativeLiveStateModules == null
            ? liveStateReader == null
                ? const <SyncModule>{}
                : Set.unmodifiable(SyncModule.values)
            : Set.unmodifiable(authoritativeLiveStateModules),
        _states = {
          for (final module in SyncModule.values)
            module: SyncModuleState(module: module),
        };

  factory SyncCenterController.forProvider(
    TimeProvider provider, {
    SyncCenterStateStore? store,
  }) {
    return SyncCenterController(
      operations: SyncCenterOperations.production(provider),
      store: store,
      liveStateReader: () => _liveStatesForProvider(provider),
      authoritativeLiveStateModules: const {
        SyncModule.schedule,
        SyncModule.googleCalendar,
      },
    );
  }

  final SyncCenterOperations _operations;
  final SyncCenterStateStore _store;
  final SyncCenterLiveStateReader? _liveStateReader;
  final Set<SyncModule> _authoritativeLiveStateModules;
  final Map<SyncModule, SyncModuleState> _states;
  final Set<SyncModule> _runningModules = {};
  Future<void>? _initializing;
  bool _initialized = false;
  bool _allRetrying = false;
  bool _disposed = false;

  List<SyncModuleState> get states => SyncModule.values
      .map((module) => _states[module]!)
      .toList(growable: false);

  SyncModuleState stateFor(SyncModule module) => _states[module]!;

  bool get isInitialized => _initialized;
  bool get isRetrying => _allRetrying || _runningModules.isNotEmpty;
  bool isRetryingModule(SyncModule module) => _runningModules.contains(module);
  int get pendingCount => states.fold(
        0,
        (total, state) =>
            total + state.pendingUploadCount + state.pendingDownloadCount,
      );
  bool get hasIssue => states.any((state) => state.hasIssue);

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    final loaded = await _store.load();
    for (final module in SyncModule.values) {
      final state = loaded[module];
      if (state == null) continue;
      // 应用在上次同步中退出时，不能把“同步中”永久显示为进行中。
      _states[module] = state.status == SyncModuleStatus.syncing ||
              state.status == SyncModuleStatus.busy
          ? state.copyWith(
              status: state.hasPending
                  ? SyncModuleStatus.pending
                  : SyncModuleStatus.idle,
              message: '上次同步未完成，可重试',
            )
          : state;
    }
    _initialized = true;
    _refreshLiveState();
    await _persist();
    _notify();
  }

  Future<void> refresh() async {
    await initialize();
    if (_disposed) return;
    _refreshLiveState();
    await _persist();
    _notify();
  }

  Future<void> retry(SyncModule module) async {
    await initialize();
    if (_disposed || _allRetrying || _runningModules.contains(module)) return;
    await _runOne(module);
  }

  /// 按固定顺序串行重试，确保不同模块不会同时读写远端或争抢 Provider 锁。
  Future<void> retryAll() async {
    await initialize();
    if (_disposed || _allRetrying || _runningModules.isNotEmpty) return;
    _allRetrying = true;
    final completedModules = <SyncModule>{};
    _notify();
    try {
      for (final module in SyncModule.values) {
        if (_disposed) return;
        await _runOne(
          module,
          fromAll: true,
          preserveLiveResults: completedModules,
        );
        completedModules.add(module);
      }
    } finally {
      _allRetrying = false;
      if (!_disposed) {
        _refreshLiveState(preserveOperationResults: completedModules);
        await _persist();
        _notify();
      }
    }
  }

  Future<void> _runOne(
    SyncModule module, {
    bool fromAll = false,
    Set<SyncModule> preserveLiveResults = const <SyncModule>{},
  }) async {
    if (_disposed || (!fromAll && _allRetrying)) return;
    _runningModules.add(module);
    _states[module] = _states[module]!.copyWith(
      status: SyncModuleStatus.syncing,
      message: '正在同步${module.label}',
    );
    _notify();

    try {
      SyncOperationResult result;
      try {
        result = await _operations.run(module);
      } catch (error) {
        result = SyncOperationResult.failed('${module.label}同步失败：$error');
      }
      if (_disposed) return;

      _applyResult(module, result);
      _runningModules.remove(module);
      final live = _readLiveState();
      if (result.status == SyncModuleStatus.busy) {
        _recoverBusyState(module, live[module]);
      }

      // 当前操作的返回值是这一轮最可靠的结果；后续模块的 live 刷新不能
      // 把它重新覆盖。retryAll 还会保护已经完成的模块。
      _refreshLiveState(
        liveState: live,
        preserveOperationResults: {
          ...preserveLiveResults,
          module,
        },
      );
      await _persist();
      _notify();
    } finally {
      // 无论业务操作、live reader 或持久化是否异常，都不能遗留“正在重试”锁。
      _runningModules.remove(module);
    }
  }

  void _applyResult(SyncModule module, SyncOperationResult result) {
    final previous = _states[module]!;
    final hasPending =
        result.pendingUploadCount > 0 || result.pendingDownloadCount > 0;
    if (result.succeeded) {
      _states[module] = previous.copyWith(
        status:
            hasPending ? SyncModuleStatus.pending : SyncModuleStatus.success,
        lastSyncAt: DateTime.now(),
        pendingUploadCount: result.pendingUploadCount,
        pendingDownloadCount: result.pendingDownloadCount,
        failureCount: 0,
        conflictCount: 0,
        message: result.message ?? '同步完成',
        details: const <String>[],
      );
      return;
    }
    if (result.status == SyncModuleStatus.disabled) {
      _states[module] = previous.copyWith(
        status: SyncModuleStatus.disabled,
        message: result.message,
      );
      return;
    }
    if (result.status == SyncModuleStatus.busy) {
      // 先记录业务层的 busy 结果；_recoverBusyState 会在 live reader
      // 明确显示任务已结束时回落，避免把 stale busy 永久留在卡片上。
      _states[module] = previous.copyWith(
        status: SyncModuleStatus.busy,
        message: result.message,
      );
      return;
    }

    _states[module] = previous.copyWith(
      status: result.status,
      pendingUploadCount:
          hasPending ? result.pendingUploadCount : previous.pendingUploadCount,
      pendingDownloadCount: hasPending
          ? result.pendingDownloadCount
          : previous.pendingDownloadCount,
      failureCount: previous.failureCount + 1,
      conflictCount: result.status == SyncModuleStatus.conflict
          ? (result.conflictCount > 0 ? result.conflictCount : 1)
          : previous.conflictCount,
      message: result.message ?? '同步未完成',
      details: result.details,
    );
  }

  void _refreshLiveState({
    Set<SyncModule> preserveOperationResults = const <SyncModule>{},
    Map<SyncModule, SyncModuleState>? liveState,
  }) {
    final live = liveState ?? _readLiveState();
    for (final module in SyncModule.values) {
      if (preserveOperationResults.contains(module) ||
          !_authoritativeLiveStateModules.contains(module)) {
        continue;
      }
      final current = _states[module]!;
      final next = live[module];
      if (next == null) continue;

      // 失败、离线、冲突是业务操作返回的终态，live reader 只有实时
      // pending/status 能力，不能把这些结果改回 syncing/idle。
      final preservePending = current.hasIssue ||
          (current.hasPending &&
              (next.status == SyncModuleStatus.busy ||
                  next.status == SyncModuleStatus.syncing));
      _states[module] = current.copyWith(
        enabled: next.enabled,
        status: _statusAfterLiveState(current, next),
        pendingUploadCount: preservePending
            ? current.pendingUploadCount
            : next.pendingUploadCount,
        pendingDownloadCount: preservePending
            ? current.pendingDownloadCount
            : next.pendingDownloadCount,
      );
    }
  }

  Map<SyncModule, SyncModuleState> _readLiveState() {
    final reader = _liveStateReader;
    if (reader == null) return const <SyncModule, SyncModuleState>{};
    try {
      return Map<SyncModule, SyncModuleState>.from(reader());
    } catch (_) {
      // 实时状态只是辅助展示；reader 异常不能阻断业务结果落地，也不能
      // 让当前模块遗留 syncing/busy 锁。
      return const <SyncModule, SyncModuleState>{};
    }
  }

  SyncModuleStatus _statusAfterLiveState(
    SyncModuleState current,
    SyncModuleState next,
  ) {
    if (!next.enabled) return SyncModuleStatus.disabled;
    if (current.hasIssue) return current.status;
    if (next.status == SyncModuleStatus.syncing) {
      return SyncModuleStatus.syncing;
    }
    if (next.status == SyncModuleStatus.busy) {
      return SyncModuleStatus.busy;
    }
    if (next.hasPending) return SyncModuleStatus.pending;

    // live reader 已明确报告任务不再运行且没有 pending，清掉旧的
    // syncing/busy/pending；其他已经完成或空闲的状态保持原样。
    return switch (current.status) {
      SyncModuleStatus.syncing ||
      SyncModuleStatus.busy ||
      SyncModuleStatus.pending ||
      SyncModuleStatus.disabled =>
        current.lastSyncAt == null
            ? SyncModuleStatus.idle
            : SyncModuleStatus.success,
      _ => current.status,
    };
  }

  void _recoverBusyState(
    SyncModule module,
    SyncModuleState? liveState,
  ) {
    final current = _states[module]!;
    if (current.status != SyncModuleStatus.busy) return;
    final next =
        _authoritativeLiveStateModules.contains(module) ? liveState : null;
    if (next != null &&
        (next.status == SyncModuleStatus.busy ||
            next.status == SyncModuleStatus.syncing)) {
      return;
    }

    final hasPending = next?.hasPending ?? current.hasPending;
    _states[module] = current.copyWith(
      enabled: next?.enabled ?? current.enabled,
      status: next?.enabled == false
          ? SyncModuleStatus.disabled
          : hasPending
              ? SyncModuleStatus.pending
              : current.lastSyncAt == null
                  ? SyncModuleStatus.idle
                  : SyncModuleStatus.success,
      pendingUploadCount: next?.pendingUploadCount ??
          (hasPending ? current.pendingUploadCount : 0),
      pendingDownloadCount: next?.pendingDownloadCount ??
          (hasPending ? current.pendingDownloadCount : 0),
      message: next == null ? current.message : '同步任务已结束，可重试',
    );
  }

  Future<void> _persist() => _store.save(states);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static Map<SyncModule, SyncModuleState> _liveStatesForProvider(
    TimeProvider provider,
  ) {
    final schedulePending = provider.pendingGiteeSyncDates.length;
    final googlePending = provider.pendingGoogleSyncDates.length;
    return {
      SyncModule.schedule: SyncModuleState(
        module: SyncModule.schedule,
        status: provider.hasScheduleSyncInFlight
            ? SyncModuleStatus.syncing
            : schedulePending > 0
                ? SyncModuleStatus.pending
                : SyncModuleStatus.idle,
        pendingUploadCount: schedulePending,
      ),
      // 这些模块没有可同步读取的 TimeProvider live state。不要用常量 0
      // 覆盖 _runOne 返回的待上传/待下载数量和失败结果；同步操作本身的
      // SyncOperationResult 才是当前一次运行的权威结果。
      SyncModule.googleCalendar: SyncModuleState(
        module: SyncModule.googleCalendar,
        enabled: provider.googleCalendarSyncEnabled,
        status: !provider.googleCalendarSyncEnabled
            ? SyncModuleStatus.disabled
            : provider.hasScheduleSyncInFlight
                ? SyncModuleStatus.syncing
                : googlePending > 0
                    ? SyncModuleStatus.pending
                    : SyncModuleStatus.idle,
        pendingUploadCount: googlePending,
      ),
    };
  }
}
