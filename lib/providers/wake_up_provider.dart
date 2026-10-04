import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/diary_kind.dart';
import '../models/sync_center_state.dart';
import '../models/wake_up_document.dart';
import '../models/wake_up_record.dart';
import '../services/app_identity_service.dart';
import '../services/app_log_service.dart';
import '../services/sync_operation_lock.dart';
import '../services/sync_status_coordinator.dart';
import '../services/wake_up_local_store.dart';
import '../services/wake_up_sync_dependencies.dart';

/// 保存持有原身份的状态对象；切身份只更换视图，不改变保存的归属。
class _WakeUpIdentityState {
  _WakeUpIdentityState(this.kind, this.document);
  final DiaryKind kind;
  WakeUpDocument document;
  SyncModuleStatus status = SyncModuleStatus.idle;
}

class WakeUpProvider extends ChangeNotifier with WidgetsBindingObserver {
  WakeUpProvider({
    WakeUpLocalStore? store,
    DateTime Function()? clock,
    WakeUpSyncDependencies? syncDependencies,
    SyncStatusCoordinator? statusCoordinator,
    bool autoSync = true,
    Duration syncDebounce = const Duration(seconds: 3),
    Duration autoRefreshInterval = const Duration(seconds: 60),
  })  : _store = store ?? WakeUpLocalStore(),
        _clock = clock ?? DateTime.now,
        _syncDependencies =
            syncDependencies ?? WakeUpSyncDependencies.disabled(),
        _statusCoordinator = statusCoordinator,
        _autoSync = autoSync,
        _syncDebounce = syncDebounce,
        _autoRefreshInterval = autoRefreshInterval {
    _isForeground = !_isBackgrounded(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    _identitySubscription = AppIdentityService.changes.listen((_) {
      unawaited(_loadIdentity());
    });
    ready = _initialize();
  }

  final WakeUpLocalStore _store;
  final DateTime Function() _clock;
  final WakeUpSyncDependencies _syncDependencies;
  final SyncStatusCoordinator? _statusCoordinator;
  final bool _autoSync;
  final Duration _syncDebounce;
  final Duration _autoRefreshInterval;
  late final StreamSubscription<void> _identitySubscription;
  late final Future<void> ready;
  _WakeUpIdentityState? _state;
  DiaryKind? _kind;
  bool _hasLoadedIdentity = false;
  bool _isLoaded = false;
  bool _disposed = false;
  bool _isForeground = true;
  int _generation = 0;
  int _pendingWrites = 0;
  Future<void>? _writeQueue;
  Future<void>? _pendingLoad;
  Future<SyncOperationResult>? _inFlight;
  _WakeUpIdentityState? _syncingState;
  _WakeUpIdentityState? _backgroundFlushState;
  bool _reportCurrentSync = true;
  bool _autoSyncOwed = false;
  Timer? _pushTimer;
  Timer? _refreshTimer;
  String? _loadError;

  DiaryKind? get kind => _kind;
  DateTime get now => _clock();
  bool get isLoaded => _isLoaded;
  bool get isSaving => _pendingWrites > 0;
  String? get loadError => _loadError;
  bool get canRecord => _state != null && _isLoaded && !isSaving;
  bool get syncEnabled => _syncDependencies.enabled;
  bool get hasPendingSync => _state?.document.pendingSync ?? false;
  SyncModuleStatus get syncStatus => _state?.status ?? SyncModuleStatus.idle;

  WakeUpRecord? recordFor(DateTime date) =>
      _state?.document.records[WakeUpRecord.keyForDate(date)];

  /// 固定取最近七个自然日，未记录的日期不参与平均值。
  List<WakeUpRecord> recentRecords(DateTime today) => [
        for (var offset = 0; offset < 7; offset++)
          if (recordFor(DateTime(today.year, today.month, today.day - offset))
              case final record?)
            record,
      ];

  int? averageMinute(DateTime today) {
    final recent = recentRecords(today);
    if (recent.isEmpty) return null;
    return (recent.fold<int>(0, (sum, record) => sum + record.minuteOfDay) /
            recent.length)
        .round();
  }

  Future<void> _initialize({bool force = false}) async {
    try {
      if (!AppIdentityService.isLoaded) await AppIdentityService.load();
      if (!_disposed) await _loadIdentity(force: force);
    } catch (error, stackTrace) {
      if (!_disposed) {
        _reportLoadError(error, stackTrace);
        _notify();
      }
    }
  }

  Future<void> reload() => _initialize(force: true);

  Future<void> _loadIdentity({bool force = false}) {
    if (_disposed) return Future.value();
    final nextKind = AppIdentityService.personKind;
    if (!force && _hasLoadedIdentity && nextKind == _kind) {
      return _pendingLoad ?? Future.value();
    }
    _stopTimers();
    final generation = ++_generation;
    _hasLoadedIdentity = true;
    _kind = nextKind;
    _state = null;
    _isLoaded = false;
    _loadError = null;
    _backgroundFlushState = null;
    _notify();
    return _pendingLoad = _readRecords(nextKind, generation);
  }

  Future<void> _readRecords(DiaryKind? kind, int generation) async {
    try {
      // 切回身份前先等其之前的保存，不能读到旧快照。
      await _writeQueue;
      var document = kind == null ? WakeUpDocument() : await _store.load(kind);
      if (_disposed || generation != _generation) return;
      if (kind != null && document.hasLegacyRecords) {
        document = document.migrateLegacyRecords();
        await _store.save(kind, document);
        if (_disposed || generation != _generation) return;
      }
      _state = kind == null ? null : _WakeUpIdentityState(kind, document);
      _isLoaded = true;
      if (_state case final state?) {
        if (state.document.pendingSync) _markPending(state);
        _ensureRefreshTimer();
        _requestAutoSync();
      }
    } catch (error, stackTrace) {
      if (_disposed || generation != _generation) return;
      _reportLoadError(error, stackTrace);
    } finally {
      if (!_disposed && generation == _generation) _notify();
    }
  }

  void _reportLoadError(Object error, StackTrace stackTrace) {
    _isLoaded = false;
    _loadError = '起床记录读取失败，请重试';
    AppLogService.instance.error('读取起床记录失败',
        source: 'wake_up', error: error, stackTrace: stackTrace);
  }

  Future<void> record(
    DateTime time, {
    required DiaryKind expectedKind,
    bool replaceExisting = true,
  }) async {
    _checkWritable(expectedKind);
    final value = WakeUpRecord(time);
    if (value.time.isAfter(now)) throw ArgumentError('起床时间不能晚于当前时间');
    final state = _state!;
    await _commit(state, (document) {
      if (!replaceExisting && document.records.containsKey(value.dateKey)) {
        return document;
      }
      final record = value.withUpdatedAt(_nextRevision(document));
      return WakeUpDocument(
          records: {...document.records, record.dateKey: record},
          deletedDates: document.deletedDates,
          pendingSync: true);
    }, allowStale: true);
    if (_isCurrent(state) && state.document.pendingSync) {
      _markPending(state);
      _schedulePush();
    }
  }

  Future<void> remove(DateTime date, {required DiaryKind expectedKind}) async {
    _checkWritable(expectedKind);
    final state = _state!;
    final key = WakeUpRecord.keyForDate(date);
    await _commit(
        state,
        (document) => WakeUpDocument(
              records: {...document.records}..remove(key),
              deletedDates: {
                ...document.deletedDates,
                key: _nextRevision(document)
              },
              pendingSync: true,
            ),
        allowStale: true);
    if (_isCurrent(state)) {
      _markPending(state);
      _schedulePush();
    }
  }

  int _nextRevision(WakeUpDocument document) {
    final current = now.millisecondsSinceEpoch;
    return current > document.latestRevision
        ? current
        : document.latestRevision + 1;
  }

  void _checkWritable(DiaryKind expectedKind) {
    if (_disposed ||
        expectedKind != _kind ||
        expectedKind != AppIdentityService.personKind) {
      throw StateError('身份已切换，请重新记录');
    }
    if (!canRecord) throw StateError('起床记录尚未就绪，请稍后重试');
  }

  /// 合并到真正提交时才读取最新状态，保留网络请求期间的新编辑。
  Future<void> _commit(_WakeUpIdentityState state,
      WakeUpDocument Function(WakeUpDocument) transform,
      {bool allowStale = false}) {
    _pendingWrites++;
    final previous = _writeQueue;
    Future<void> save() async {
      if (previous != null) await previous;
      if (!allowStale && !_isCurrent(state)) return;
      final next = transform(state.document);
      if (next.equivalentTo(state.document) &&
          next.pendingSync == state.document.pendingSync) {
        return;
      }
      await _store.save(state.kind, next);
      state.document = next;
    }

    final operation = save();
    final completed = operation.whenComplete(() {
      _pendingWrites--;
      _notify();
    });
    // 上一次失败不能阻塞后续保存或身份加载。
    _writeQueue =
        completed.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      AppLogService.instance.error('保存起床记录失败',
          source: 'wake_up', error: error, stackTrace: stack);
    });
    _notify();
    return completed;
  }

  bool _isCurrent(_WakeUpIdentityState state) =>
      !_disposed &&
      identical(state, _state) &&
      AppIdentityService.personKind == state.kind;

  /// 自动刷新与同步中心共用入口：先拉取、合并、落盘，再按 SHA 上传。
  Future<SyncOperationResult> synchronize({
    String source = '起床记录',
    bool reportStatus = true,
    bool allowBackground = false,
  }) async {
    await ready;
    await _pendingLoad;
    if (!_syncDependencies.enabled) {
      return const SyncOperationResult.disabled('起床记录同步未启用');
    }
    final state = _state;
    if (state == null || !_isLoaded || !_isCurrent(state)) {
      return const SyncOperationResult.offline('请先选择身份并加载起床记录');
    }
    if (!_isForeground && !allowBackground) {
      return const SyncOperationResult.skipped('应用在后台，等待返回后同步');
    }
    final previous = _inFlight;
    if (previous != null) {
      if (identical(state, _syncingState)) {
        if (!reportStatus) _reportCurrentSync = false;
        return previous;
      }
      await previous;
      return synchronize(
          source: source,
          reportStatus: reportStatus,
          allowBackground: allowBackground);
    }
    _pushTimer?.cancel();
    _pushTimer = null;
    _syncingState = state;
    _reportCurrentSync = reportStatus;
    state.status = SyncModuleStatus.syncing;
    if (reportStatus) {
      _statusCoordinator?.begin(SyncModule.wakeUp,
          source: source, scope: state.kind.code);
    }
    final operation = SyncOperationLock.instance.run(SyncModule.wakeUp,
        () => _synchronizeState(state, allowBackground: allowBackground));
    _inFlight = operation;
    _notify();
    try {
      final result = await operation;
      state.status = result.status;
      if (_reportCurrentSync) {
        _statusCoordinator?.report(SyncModule.wakeUp, result,
            source: source, scope: state.kind.code);
      }
      return result;
    } finally {
      _inFlight = null;
      _syncingState = null;
      _notify();
      final backgroundState = _backgroundFlushState;
      _backgroundFlushState = null;
      if (!_isForeground &&
          backgroundState != null &&
          _isCurrent(backgroundState) &&
          backgroundState.document.pendingSync) {
        unawaited(synchronize(allowBackground: true, source: '切后台补同步'));
      } else if (_autoSyncOwed) {
        _autoSyncOwed = false;
        _schedulePush();
      }
    }
  }

  Future<SyncOperationResult> _synchronizeState(_WakeUpIdentityState state,
      {required bool allowBackground}) async {
    bool canContinue() =>
        _isCurrent(state) && (_isForeground || allowBackground);
    SyncOperationResult skipped() =>
        const SyncOperationResult.skipped('身份或前后台状态已变化，稍后重新同步');
    int pending() => state.document.pendingSync ? 1 : 0;
    try {
      final token = await _syncDependencies.loadToken();
      if (!canContinue()) return skipped();
      if (token == null || token.trim().isEmpty) {
        return SyncOperationResult.offline('Gitee 未连接，起床记录已保存在本机',
            pendingUploadCount: pending());
      }
      for (var attempt = 0; attempt < 3; attempt++) {
        final pull = await _syncDependencies.pull(
            token: token, userCode: state.kind.code);
        if (!canContinue()) return skipped();
        if (!pull.success && !pull.notFound) {
          return SyncOperationResult.failed('起床记录拉取失败：${pull.error ?? '远端不可用'}',
              pendingUploadCount: pending());
        }
        if (pull.success && (pull.content == null || pull.sha == null)) {
          return SyncOperationResult.failed('远端起床记录缺少内容或版本，暂不上传',
              pendingUploadCount: pending(), pendingDownloadCount: 1);
        }
        final remote = pull.notFound
            ? WakeUpDocument()
            : WakeUpDocument.decode(pull.content!, allowLegacy: false);
        await _commit(state, (local) {
          final merged = WakeUpDocument.merge(local, remote);
          return merged.withPending(!merged.equivalentTo(remote));
        });
        if (!canContinue()) return skipped();
        final outgoing = state.document;
        if (outgoing.equivalentTo(remote)) {
          return const SyncOperationResult.success(message: '起床记录已同步');
        }
        final push = await _syncDependencies.push(
          token: token,
          userCode: state.kind.code,
          content: outgoing.encode(),
          commitMessage: 'wake_up(${state.kind.code}): sync',
          expectedSha: pull.sha,
          expectNotFound: pull.notFound,
        );
        if (!canContinue()) return skipped();
        if (!push.success) {
          if (push.conflict && attempt < 2) continue;
          return push.conflict
              ? SyncOperationResult.conflict('另一台设备正在修改起床记录，请稍后重试',
                  pendingUploadCount: pending())
              : SyncOperationResult.failed('起床记录上传失败：${push.error ?? '远端不可用'}',
                  pendingUploadCount: pending());
        }
        // 上传期间的新修改仍需保留待上传标记。
        await _commit(state,
            (latest) => latest.withPending(!latest.equivalentTo(outgoing)));
        if (!canContinue()) return skipped();
        return state.document.pendingSync
            ? const SyncOperationResult.pending('起床记录已上传，仍有新修改待同步',
                pendingUploadCount: 1)
            : const SyncOperationResult.success(message: '起床记录已同步');
      }
      return SyncOperationResult.conflict('起床记录版本冲突，请稍后重试',
          pendingUploadCount: pending());
    } catch (error, stackTrace) {
      AppLogService.instance.error('起床记录同步失败',
          source: 'wake_up', error: error, stackTrace: stackTrace);
      return SyncOperationResult.failed('起床记录同步失败，本地记录已保留',
          pendingUploadCount: pending(), pendingDownloadCount: 1);
    }
  }

  void _markPending(_WakeUpIdentityState state) {
    state.status = SyncModuleStatus.pending;
    _statusCoordinator?.markPending(SyncModule.wakeUp,
        uploadCount: 1,
        message: '有起床记录待上传',
        source: '目标页',
        scope: state.kind.code);
    _notify();
  }

  void _schedulePush() {
    _pushTimer?.cancel();
    if (!_autoSync ||
        !syncEnabled ||
        !_isForeground ||
        _disposed ||
        _state == null) {
      return;
    }
    _pushTimer = Timer(_syncDebounce, _requestAutoSync);
  }

  void _requestAutoSync() {
    if (!_autoSync ||
        !syncEnabled ||
        !_isForeground ||
        _disposed ||
        _state == null) {
      return;
    }
    if (_inFlight != null) {
      _autoSyncOwed = true;
      return;
    }
    unawaited(synchronize(source: '起床记录自动同步'));
  }

  void _ensureRefreshTimer() {
    _refreshTimer?.cancel();
    if (_autoSync &&
        syncEnabled &&
        _isForeground &&
        !_disposed &&
        _state != null) {
      _refreshTimer =
          Timer.periodic(_autoRefreshInterval, (_) => _requestAutoSync());
    }
  }

  static bool _isBackgrounded(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isBackgrounded(state)) {
      unawaited(onAppBackgrounded());
    } else if (state == AppLifecycleState.resumed) {
      onAppResumed();
    }
  }

  Future<void> onAppBackgrounded() async {
    _isForeground = false;
    _stopTimers();
    if (!_autoSync || !syncEnabled || _disposed) return;
    final state = _state;
    await _writeQueue;
    if (state == null || !_isCurrent(state) || !state.document.pendingSync) {
      return;
    }
    if (_inFlight != null) {
      _backgroundFlushState = state;
      return;
    }
    await synchronize(allowBackground: true, source: '切后台补同步');
  }

  void onAppResumed() {
    _isForeground = true;
    _backgroundFlushState = null;
    _ensureRefreshTimer();
    _requestAutoSync();
  }

  void _stopTimers() {
    _pushTimer?.cancel();
    _refreshTimer?.cancel();
    _pushTimer = null;
    _refreshTimer = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_identitySubscription.cancel());
    super.dispose();
  }
}
