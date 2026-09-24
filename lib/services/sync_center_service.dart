import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/sync_center_state.dart';
import '../models/travel_record.dart';
import '../providers/time_provider.dart';
import 'check_in_sync_service.dart';
import 'diary_local_store.dart';
import 'diary_sync_service.dart';
import 'sync_operation_lock.dart';
import 'sync_status_coordinator.dart';
import 'travel_gitee_service.dart';
import 'travel_local_store.dart';

export 'sync_status_coordinator.dart'
    show
        InMemorySyncStatusStore,
        SharedPreferencesSyncStatusStore,
        SyncStatusCoordinator,
        SyncStatusStore;

typedef SyncCenterOperation = Future<SyncOperationResult> Function();

/// 读取宿主当前实时同步状态。
///
/// 返回值是部分映射：只有确实能提供可靠实时状态的模块才应返回。控制器
/// 会结合控制器构造函数的 `authoritativeLiveStateModules` 参数决定哪些模块
/// 可以覆盖同步中心状态；未提供可靠 reader 的模块继续使用最近一次业务操作
/// 的结果，避免用默认的 0 清掉待同步照片或其他失败信息。
typedef SyncCenterLiveStateReader = Map<SyncModule, SyncModuleState> Function();

/// 业务同步入口的集合。同步中心只编排，不复制各模块的远端协议。
class SyncCenterOperations {
  SyncCenterOperations(
      {required Map<SyncModule, SyncCenterOperation> operations,
      Map<SyncModule, SyncCenterOperation> checks = const {},
      this.recoverScheduleOverwrite})
      : _operations = Map.unmodifiable(operations),
        _checks = Map.unmodifiable(checks);

  final Map<SyncModule, SyncCenterOperation> _operations;
  final Map<SyncModule, SyncCenterOperation> _checks;

  /// 破坏性的「覆盖拉取日程」恢复入口：以远端为准覆盖本地、不合并。
  final SyncCenterOperation? recoverScheduleOverwrite;

  Set<SyncModule> get checkableModules => _checks.keys.toSet();

  SyncCenterOperation? checkFor(SyncModule module) => _checks[module];

  Future<SyncOperationResult> run(SyncModule module) async {
    final operation = _operations[module];
    if (operation == null) {
      return SyncOperationResult.failed('${module.label}暂不支持同步');
    }
    return operation();
  }

  Future<SyncOperationResult> check(SyncModule module) async {
    final operation = _checks[module];
    if (operation == null) {
      return SyncOperationResult.skipped('${module.label}暂不支持实时检查');
    }
    return operation();
  }

  factory SyncCenterOperations.production(TimeProvider provider) {
    final checkIn = CheckInSyncService();
    final diary = DiarySyncService();
    return SyncCenterOperations(
      operations: {
        for (final module in [
          SyncModule.schedule,
          SyncModule.categories,
          SyncModule.targets,
          SyncModule.googleCalendar,
        ])
          module: () => provider.syncModuleForCenter(module),
        SyncModule.diary: diary.sync,
        SyncModule.travel: _syncTravel,
        SyncModule.checkIn: () => _syncCheckIn(checkIn),
      },
      checks: {
        SyncModule.schedule: provider.checkScheduleSyncState,
      },
      recoverScheduleOverwrite: () async {
        final ok = await provider.overwriteAllSchedulesFromGitee();
        return ok
            ? const SyncOperationResult.success(message: '覆盖拉取完成')
            : SyncOperationResult.failed(
                provider.lastScheduleOverwriteFailure ?? '覆盖拉取未开始或失败，请稍后重试',
              );
      },
    );
  }

  static Future<SyncOperationResult> _syncTravel() {
    return SyncOperationLock.instance.run(
      SyncModule.travel,
      _syncTravelInternal,
    );
  }

  static Future<SyncOperationResult> _syncTravelInternal() async {
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
    if (outgoing.toSyncPayload() == remote.toSyncPayload()) {
      await TravelLocalStore.saveDraft(outgoing.toMarkdown());
      return const SyncOperationResult.success(message: '出行记录已确认同步');
    }
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
    await sync.initialize(silent: true, retryPhotoCleanup: false);
    final result = await sync.pushToGitHub();
    if (!result.success) {
      final message = result.error ?? '打卡同步失败';
      if (message.contains('未配置') || message.contains('身份')) {
        return SyncOperationResult.offline(message, pendingUploadCount: 1);
      }
      return SyncOperationResult.failed(message, pendingUploadCount: 1);
    }

    // pushToGitHub 只代表打卡主文档完成。照片清理是删除目标/记录后的
    // 第二个远端操作，必须等待它的真实结果，否则同步中心会把仍有孤儿
    // 照片待清理的状态误报为“全部完成”。
    final cleanup = await sync.retryPendingPhotoCleanup();
    if (!cleanup.success) {
      return SyncOperationResult.failed(
        '打卡数据已同步，但${cleanup.error ?? '照片清理失败'}',
        pendingUploadCount: 1,
      );
    }
    if (cleanup.warning != null) {
      return SyncOperationResult.pending(
        '打卡数据已同步，但${cleanup.warning}',
        pendingUploadCount: 1,
      );
    }
    return const SyncOperationResult.success(message: '打卡数据已同步');
  }
}

/// 同步中心的状态编排器。状态本身由全局 [SyncStatusCoordinator] 持有，
/// 因此日程页、出行页和后台自动同步的结果与同步中心共享同一份数据；
/// 控制器只负责编排「全部重试」和防止同模块重复发起。
class SyncCenterController extends ChangeNotifier {
  SyncCenterController({
    required SyncCenterOperations operations,
    SyncStatusCoordinator? coordinator,
    SyncStatusStore? store,
    bool loadIdentityBeforeState = true,
    Future<void> Function()? waitForLiveState,
    Listenable? liveStateSource,
    SyncCenterLiveStateReader? liveStateReader,
    Set<SyncModule>? authoritativeLiveStateModules,
  })  : _operations = operations,
        _coordinator = coordinator ??
            SyncStatusCoordinator(
              store: store,
              loadIdentityBeforeState: loadIdentityBeforeState,
            ),
        _ownsCoordinator = coordinator == null,
        _waitForLiveState = waitForLiveState,
        _liveStateSource = liveStateSource,
        _liveStateReader = liveStateReader,
        _authoritativeLiveStateModules = authoritativeLiveStateModules == null
            ? liveStateReader == null
                ? const <SyncModule>{}
                : Set.unmodifiable(SyncModule.values)
            : Set.unmodifiable(authoritativeLiveStateModules) {
    _coordinator.addListener(_notify);
    _liveStateSource?.addListener(_scheduleLiveStateRefresh);
  }

  factory SyncCenterController.forProvider(
    TimeProvider provider, {
    SyncStatusCoordinator? coordinator,
    SyncStatusStore? store,
    bool loadIdentityBeforeState = true,
  }) {
    return SyncCenterController(
      operations: SyncCenterOperations.production(provider),
      coordinator: coordinator,
      store: store,
      loadIdentityBeforeState: loadIdentityBeforeState,
      waitForLiveState: provider.waitForSyncReady,
      liveStateSource: provider,
      liveStateReader: () => _liveStatesForProvider(provider),
      authoritativeLiveStateModules: const {
        SyncModule.schedule,
        SyncModule.googleCalendar,
      },
    );
  }

  final SyncCenterOperations _operations;
  final SyncStatusCoordinator _coordinator;
  final bool _ownsCoordinator;
  final Future<void> Function()? _waitForLiveState;
  final Listenable? _liveStateSource;
  final SyncCenterLiveStateReader? _liveStateReader;
  final Set<SyncModule> _authoritativeLiveStateModules;
  final Set<SyncModule> _runningModules = {};
  Future<void>? _initializing;
  bool _initialized = false;
  bool _allRetrying = false;
  bool _disposed = false;
  bool _liveRefreshScheduled = false;

  SyncStatusCoordinator get coordinator => _coordinator;

  List<SyncModuleState> get states => _coordinator.states;

  SyncModuleState stateFor(SyncModule module) => _coordinator.stateFor(module);

  bool get isInitialized => _initialized;
  bool get isRetrying => _allRetrying || _runningModules.isNotEmpty;
  bool isRetryingModule(SyncModule module) => _runningModules.contains(module);
  int get pendingCount => _coordinator.pendingCount;
  bool get hasIssue => _coordinator.hasIssue;
  bool get hasUnresolved => states.any(
        (state) =>
            state.hasIssue ||
            state.hasPending ||
            state.status == SyncModuleStatus.syncing ||
            state.status == SyncModuleStatus.busy,
      );

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    final waitForLiveState = _waitForLiveState;
    if (waitForLiveState == null) {
      await _coordinator.initialize();
    } else {
      await Future.wait<void>([
        _coordinator.initialize(),
        waitForLiveState(),
      ]);
    }
    if (_disposed) return;
    _initialized = true;
    // 刷新只读取实时 pending/进行中状态，不会把已经成功的时间重置。
    _refreshLiveState();
    _notify();
  }

  Future<void> refresh() async {
    await initialize();
    if (_disposed) return;
    _coordinator.refreshContext();
    _refreshLiveState();
    _notify();
    await _runChecks();
  }

  Future<void> retry(SyncModule module) async {
    await initialize();
    if (_disposed || _allRetrying || _runningModules.contains(module)) return;
    await _runOne(module);
  }

  /// 覆盖拉取日程（破坏性恢复入口）。
  ///
  /// 复用 [_runOne] 的并发锁与统一上报，结果落到「日程」模块卡片上；返回结果
  /// 供页面提示。已有日程任务在执行时返回 null（不重复发起危险并发操作）。
  Future<SyncOperationResult?> recoverScheduleOverwrite() async {
    await initialize();
    final operation = _operations.recoverScheduleOverwrite;
    if (_disposed ||
        operation == null ||
        _allRetrying ||
        _runningModules.contains(SyncModule.schedule)) {
      return null;
    }
    SyncOperationResult? result;
    await _runOne(
      SyncModule.schedule,
      operation: () async {
        try {
          final value = await operation();
          result = value;
          return value;
        } catch (error) {
          final failure = SyncOperationResult.failed('覆盖拉取失败：$error');
          result = failure;
          return failure;
        }
      },
    );
    return result;
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
        _notify();
      }
    }
  }

  Future<void> _runOne(
    SyncModule module, {
    bool fromAll = false,
    Set<SyncModule> preserveLiveResults = const <SyncModule>{},
    SyncCenterOperation? operation,
    bool checking = false,
  }) async {
    if (_disposed ||
        (!fromAll && _allRetrying) ||
        _runningModules.contains(module)) {
      return;
    }
    _runningModules.add(module);
    final scope = _coordinator.scopeFor(module);
    _coordinator.begin(
      module,
      message: checking ? '正在检查${module.label}' : '正在同步${module.label}',
      source: _allRetrying ? '同步中心（全部重试）' : '同步中心',
      scope: scope,
    );
    _notify();

    try {
      SyncOperationResult result;
      try {
        result =
            await (operation == null ? _operations.run(module) : operation());
      } catch (error) {
        result = SyncOperationResult.failed('${module.label}同步失败：$error');
      }
      if (_disposed) return;

      _coordinator.report(
        module,
        result,
        source: _allRetrying ? '同步中心（全部重试）' : '同步中心',
        scope: scope,
      );
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
      _notify();
    } finally {
      // 无论业务操作、live reader 或持久化是否异常，都不能遗留“正在重试”锁。
      _runningModules.remove(module);
    }
  }

  Future<void> _runChecks() async {
    for (final module in _operations.checkableModules) {
      if (_disposed) return;
      final operation = _operations.checkFor(module);
      if (operation == null) continue;
      await _runOne(
        module,
        operation: operation,
        checking: true,
      );
    }
  }

  void _refreshLiveState({
    Set<SyncModule> preserveOperationResults = const <SyncModule>{},
    Map<SyncModule, SyncModuleState>? liveState,
  }) {
    final live = liveState ?? _readLiveState();
    _coordinator.batch(() {
      for (final module in SyncModule.values) {
        if (preserveOperationResults.contains(module) ||
            !_authoritativeLiveStateModules.contains(module)) {
          continue;
        }
        final next = live[module];
        if (next == null) continue;
        _coordinator.update(module, (current) {
          // 失败、离线、冲突是业务操作返回的终态，live reader 只有实时
          // pending/status 能力，不能把这些结果改回 syncing/idle。
          final preservePending = current.hasIssue ||
              (current.hasPending &&
                  (next.status == SyncModuleStatus.busy ||
                      next.status == SyncModuleStatus.syncing));
          return current.copyWith(
            enabled: next.enabled,
            status: _statusAfterLiveState(current, next),
            pendingUploadCount: preservePending
                ? current.pendingUploadCount
                : next.pendingUploadCount,
            pendingDownloadCount: preservePending
                ? current.pendingDownloadCount
                : next.pendingDownloadCount,
          );
        });
      }
    });
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
        current.lastSuccessAt == null
            ? SyncModuleStatus.idle
            : SyncModuleStatus.success,
      _ => current.status,
    };
  }

  void _recoverBusyState(
    SyncModule module,
    SyncModuleState? liveState,
  ) {
    _coordinator.update(module, (current) {
      if (current.status != SyncModuleStatus.busy) return current;
      final next =
          _authoritativeLiveStateModules.contains(module) ? liveState : null;
      if (next != null &&
          (next.status == SyncModuleStatus.busy ||
              next.status == SyncModuleStatus.syncing)) {
        return current;
      }

      final hasPending = next?.hasPending ?? current.hasPending;
      return current.copyWith(
        enabled: next?.enabled ?? current.enabled,
        status: next?.enabled == false
            ? SyncModuleStatus.disabled
            : hasPending
                ? SyncModuleStatus.pending
                : current.lastSuccessAt == null
                    ? SyncModuleStatus.idle
                    : SyncModuleStatus.success,
        pendingUploadCount: next?.pendingUploadCount ??
            (hasPending ? current.pendingUploadCount : 0),
        pendingDownloadCount: next?.pendingDownloadCount ??
            (hasPending ? current.pendingDownloadCount : 0),
        message: next == null ? current.message : '同步任务已结束，可重试',
      );
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _scheduleLiveStateRefresh() {
    if (_disposed || !_initialized || _liveRefreshScheduled) return;
    _liveRefreshScheduled = true;
    scheduleMicrotask(() {
      _liveRefreshScheduled = false;
      if (_disposed || !_initialized) return;
      // Provider 的身份切换会在状态尚未完全落地时先发一次通知；放到微任务
      // 中刷新，确保读到的是切换后的 pending，而不是中间态的空集合。
      _refreshLiveState(preserveOperationResults: _runningModules);
      _notify();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _coordinator.removeListener(_notify);
    _liveStateSource?.removeListener(_scheduleLiveStateRefresh);
    if (_ownsCoordinator) _coordinator.dispose();
    super.dispose();
  }

  static Map<SyncModule, SyncModuleState> _liveStatesForProvider(
    TimeProvider provider,
  ) {
    if (!provider.isSyncStateReady) return const {};
    final schedulePending = provider.pendingGiteeSyncDates.length;
    final googlePending = provider.pendingGoogleSyncDates.length;
    return {
      SyncModule.schedule: SyncModuleState(
        module: SyncModule.schedule,
        status: provider.hasScheduleModuleSyncInFlight
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
            : provider.hasGoogleCalendarSyncInFlight
                ? SyncModuleStatus.syncing
                : googlePending > 0
                    ? SyncModuleStatus.pending
                    : SyncModuleStatus.idle,
        pendingUploadCount: googlePending,
      ),
    };
  }
}
