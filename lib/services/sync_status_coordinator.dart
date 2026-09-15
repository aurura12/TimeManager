import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/diary_kind.dart';
import '../models/remote_sync_platform.dart';
import '../models/sync_center_state.dart';
import 'app_identity_service.dart';

/// 读取模块当前同步上下文的后缀（身份、Google 账号、远端平台）。
///
/// 协调器把「模块 + 上下文」作为状态的存储键，因而切换身份后不会显示
/// 另一个身份的同步时间。
typedef SyncScopeResolver = String Function(SyncModule module);

abstract interface class SyncStatusStore {
  /// 返回以 `模块:上下文` 为键的状态映射。
  Future<Map<String, SyncModuleState>> load();

  Future<void> save(Map<String, SyncModuleState> states);
}

/// 同步状态的本地存储。只保存状态和时间，不保存任何凭据。
class SharedPreferencesSyncStatusStore implements SyncStatusStore {
  static const String storageKey = 'sync_center_state_v2';
  static const String legacyStorageKey = 'sync_center_state_v1';

  @override
  Future<Map<String, SyncModuleState>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      final migrated = _decode(raw);
      if (migrated.isNotEmpty) return migrated;

      // v1 是全局单份状态，没有身份信息。迁移时只保留可确定的本地事实
      // （enabled、待上传数量），并清掉成功时间，避免切换身份后展示上
      // 一个身份的同步时间，也避免首次安装误显示为已同步。
      return _migrateLegacy(prefs.getString(legacyStorageKey));
    } catch (_) {
      return const {};
    }
  }

  Map<String, SyncModuleState> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};

    final result = <String, SyncModuleState>{};
    for (final module in SyncModule.values) {
      final prefix = '${module.storageKey}:';
      decoded.forEach((key, value) {
        final name = key.toString();
        if (!name.startsWith(prefix) || value is! Map) return;
        result[name] = SyncModuleState.fromJson(
          module,
          Map<String, dynamic>.from(value),
        );
      });
    }
    return result;
  }

  Map<String, SyncModuleState> _migrateLegacy(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};

    final result = <String, SyncModuleState>{};
    for (final module in SyncModule.values) {
      final Object? value = decoded[module.storageKey];
      if (value is! Map) continue;
      final state = SyncModuleState.fromJson(
        module,
        Map<String, dynamic>.from(value),
      );
      result[SyncStatusCoordinator.defaultContextKeyFor(module)] =
          state.copyWith(
        status: state.enabled
            ? (state.hasPending ? SyncModuleStatus.pending : SyncModuleStatus.idle)
            : SyncModuleStatus.disabled,
        lastAttemptAt: null,
        lastSuccessAt: null,
        failureCount: 0,
        conflictCount: 0,
        message: '首次启用同步状态，等待本次同步确认',
        details: const <String>[],
      );
    }
    return result;
  }

  @override
  Future<void> save(Map<String, SyncModuleState> states) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        for (final entry in states.entries) entry.key: entry.value.toJson(),
      };
      await prefs.setString(storageKey, jsonEncode(payload));
    } catch (_) {
      // 状态展示失败不能影响业务数据同步。
    }
  }
}

/// 用于单元测试或宿主暂时不需要持久化时的内存状态存储。
class InMemorySyncStatusStore implements SyncStatusStore {
  InMemorySyncStatusStore([Map<String, SyncModuleState>? initial])
      : _states = {...?initial};

  Map<String, SyncModuleState> _states;

  @override
  Future<Map<String, SyncModuleState>> load() async => {..._states};

  @override
  Future<void> save(Map<String, SyncModuleState> states) async {
    _states = {...states};
  }
}

/// 全局同步状态中心。
///
/// 同步中心页面、日程页、出行页、日记页和打卡服务都通过它读写同一份
/// 状态，避免「实际同步成功但同步中心显示未同步」。
class SyncStatusCoordinator extends ChangeNotifier {
  SyncStatusCoordinator({
    SyncStatusStore? store,
    SyncScopeResolver? scopeResolver,
  })  : _store = store ?? SharedPreferencesSyncStatusStore(),
        _scopeResolver = scopeResolver ?? defaultScopeFor {
    // 身份/账号切换后要立刻按新上下文展示，否则页面会停留在上一个身份
    // 的“已同步”时间上。
    _identitySubscription = AppIdentityService.changes.listen((_) {
      refreshContext();
    });
    unawaited(initialize());
  }

  final SyncStatusStore _store;
  final SyncScopeResolver _scopeResolver;
  final Map<String, SyncModuleState> _states = {};
  StreamSubscription<void>? _identitySubscription;
  Future<void>? _initializing;
  Future<void> _saveChain = Future<void>.value();
  bool _loaded = false;
  bool _disposed = false;
  bool _suppressNotify = false;

  /// 默认上下文：日程/分类/目标/日记/出行/打卡按当前身份隔离，Google
  /// 日历按 Google 账号隔离。
  static String defaultScopeFor(SyncModule module) {
    if (module == SyncModule.googleCalendar) {
      return AppIdentityService.googleUser?.id ?? 'none';
    }
    final person = AppIdentityService.personKind?.code ?? 'unbound';
    if (module == SyncModule.diary || module == SyncModule.travel) {
      return '$person:${RemoteSyncPlatform.gitee.name}';
    }
    return person;
  }

  static String defaultContextKeyFor(SyncModule module) =>
      '${module.storageKey}:${defaultScopeFor(module)}';

  String contextKeyFor(SyncModule module, {String? scope}) =>
      '${module.storageKey}:${scope ?? _scopeResolver(module)}';

  Future<void> initialize() {
    if (_loaded) return Future<void>.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    final loaded = await _store.load();
    if (_disposed) return;
    for (final entry in loaded.entries) {
      var state = entry.value;
      // 应用在上次同步中退出时，不能把“同步中”永久显示为进行中。
      if (state.status == SyncModuleStatus.syncing ||
          state.status == SyncModuleStatus.busy) {
        state = state.copyWith(
          status: state.hasPending
              ? SyncModuleStatus.pending
              : (state.lastSuccessAt == null
                  ? SyncModuleStatus.idle
                  : SyncModuleStatus.success),
          message: '上次同步未完成，可重试',
        );
      }
      // 读盘是异步的：初始化期间已经收到的实时上报（例如打开应用时马上
      // 完成的自动同步）比磁盘快照更新，不能被旧快照覆盖。
      _states.putIfAbsent(entry.key, () => state);
    }
    _loaded = true;
    if (_disposed) return;
    // 初始化期间收到的上报已经合并进内存，这里补一次落盘。
    _scheduleSave();
    notifyListeners();
  }

  /// 身份或账号切换后重新解析上下文，让页面按当前上下文展示。
  void refreshContext() {
    if (_disposed) return;
    notifyListeners();
  }

  List<SyncModuleState> get states => SyncModule.values
      .map(stateFor)
      .toList(growable: false);

  SyncModuleState stateFor(SyncModule module) =>
      _states[contextKeyFor(module)] ?? SyncModuleState(module: module);

  /// 已记录过状态的上下文数量，用于测试与调试断言。
  int get recordedContextCount => _states.length;

  int get pendingCount => states.fold(
        0,
        (total, state) =>
            total + state.pendingUploadCount + state.pendingDownloadCount,
      );

  bool get hasIssue => states.any((state) => state.hasIssue);

  /// 批量修改状态，期间只通知和落盘一次。
  void batch(void Function() action) {
    if (_disposed) return;
    _suppressNotify = true;
    try {
      action();
    } finally {
      _suppressNotify = false;
      _notify();
      _scheduleSave();
    }
  }

  void update(
    SyncModule module,
    SyncModuleState Function(SyncModuleState current) transform, {
    String? scope,
  }) {
    if (_disposed) return;
    final key = contextKeyFor(module, scope: scope);
    final current = _states[key] ?? SyncModuleState(module: module);
    _states[key] = transform(current);
    _notify();
    _scheduleSave();
  }

  /// 上报「开始同步」。
  void begin(
    SyncModule module, {
    String? message,
    String? source,
    String? scope,
  }) {
    update(
      module,
      (current) => current.copyWith(
        status: SyncModuleStatus.syncing,
        message: message ?? '正在同步${module.label}',
        source: source ?? current.source,
        scope: scope ?? current.scope,
      ),
      scope: scope,
    );
  }

  /// 上报一次同步结果。成功时清除待处理数量并记录成功时间；失败时保留
  /// 上一次成功时间，只累加失败次数。
  void report(
    SyncModule module,
    SyncOperationResult result, {
    String? source,
    String? scope,
  }) {
    update(
      module,
      (current) => applyResult(
        current,
        result,
        source: source,
        scope: scope,
      ),
      scope: scope,
    );
  }

  /// 纯函数版本的 [report]，便于控制器与测试复用。
  static SyncModuleState applyResult(
    SyncModuleState current,
    SyncOperationResult result, {
    String? source,
    String? scope,
  }) {
    final now = DateTime.now();
    final hasPending =
        result.pendingUploadCount > 0 || result.pendingDownloadCount > 0;
    final base = current.copyWith(
      source: source ?? current.source,
      scope: scope ?? current.scope,
    );

    if (result.succeeded) {
      return base.copyWith(
        status:
            hasPending ? SyncModuleStatus.pending : SyncModuleStatus.success,
        lastAttemptAt: now,
        lastSuccessAt: now,
        pendingUploadCount: result.pendingUploadCount,
        pendingDownloadCount: result.pendingDownloadCount,
        failureCount: 0,
        conflictCount: 0,
        message: result.message ?? '同步完成',
        details: const <String>[],
      );
    }
    if (result.status == SyncModuleStatus.disabled) {
      return base.copyWith(
        status: SyncModuleStatus.disabled,
        message: result.message,
        details: const <String>[],
      );
    }
    if (result.status == SyncModuleStatus.busy) {
      // 业务层的 busy 结果由控制器的 live reader 回落，不能在这里改成
      // 失败，也不能累加失败次数。
      return base.copyWith(
        status: SyncModuleStatus.busy,
        message: result.message,
      );
    }

    return base.copyWith(
      status: result.status,
      lastAttemptAt: now,
      pendingUploadCount:
          hasPending ? result.pendingUploadCount : current.pendingUploadCount,
      pendingDownloadCount: hasPending
          ? result.pendingDownloadCount
          : current.pendingDownloadCount,
      failureCount: current.failureCount + 1,
      conflictCount: result.status == SyncModuleStatus.conflict
          ? (result.conflictCount > 0 ? result.conflictCount : 1)
          : current.conflictCount,
      message: result.message ?? '同步未完成',
      details: result.details,
    );
  }

  /// 本地修改后立即标记待上传。
  ///
  /// 计数是绝对值而不是累加：连续编辑同一份数据不应该把待上传数量越滚
  /// 越大，调用方传入当前真实的待上传条数。
  void markPending(
    SyncModule module, {
    int? uploadCount,
    int? downloadCount,
    String? message,
    String? source,
    String? scope,
  }) {
    update(
      module,
      (current) {
        final upload = uploadCount ?? current.pendingUploadCount;
        final download = downloadCount ?? current.pendingDownloadCount;
        return current.copyWith(
          status: upload > 0 || download > 0
              ? SyncModuleStatus.pending
              : current.status,
          pendingUploadCount: upload,
          pendingDownloadCount: download,
          message: message ?? current.message,
          source: source ?? current.source,
          scope: scope ?? current.scope,
        );
      },
      scope: scope,
    );
  }

  /// 同步成功后清除待上传标记，保留最近一次成功时间。
  void clearPending(
    SyncModule module, {
    String? message,
    String? source,
    String? scope,
  }) {
    update(
      module,
      (current) => current.copyWith(
        status: current.hasIssue
            ? current.status
            : (current.lastSuccessAt == null
                ? SyncModuleStatus.idle
                : SyncModuleStatus.success),
        pendingUploadCount: 0,
        pendingDownloadCount: 0,
        message: message ?? current.message,
        source: source ?? current.source,
        scope: scope ?? current.scope,
      ),
      scope: scope,
    );
  }

  void reportDisabled(SyncModule module, String message) {
    update(
      module,
      (current) => current.copyWith(
        status: SyncModuleStatus.disabled,
        message: message,
      ),
    );
  }

  void _notify() {
    if (_disposed || _suppressNotify) return;
    notifyListeners();
  }

  void _scheduleSave() {
    // 读盘完成前落盘会丢掉尚未加载的上下文，等 initialize 结束时统一保存。
    if (_disposed || !_loaded) return;
    final snapshot = Map<String, SyncModuleState>.from(_states);
    _saveChain = _saveChain.then((_) {
      if (_disposed) return Future<void>.value();
      return _store.save(snapshot);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _identitySubscription?.cancel();
    _identitySubscription = null;
    super.dispose();
  }
}
