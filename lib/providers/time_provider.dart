import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' hide Category;
import '../models/time_slot.dart'; // 确保导入了模型
import '../models/category.dart';
import 'dart:convert';
import '../services/google_calendar_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../models/target.dart';
import '../models/schedule_template.dart';
import '../models/calendar_block.dart';
import '../models/search_result.dart';
import '../models/voice_schedule_draft.dart';
import '../models/pending_sync_state.dart';
import '../services/home_widget_service.dart';
import '../utils/platform_features.dart';
import '../services/diary_local_store.dart';
import '../services/schedule_day_merge.dart';
import '../services/schedule_gitee_service.dart';
import '../services/schedule_overwrite.dart';
import '../services/schedule_sync_dependencies.dart';
import '../services/category_document_merge.dart';
import '../services/category_gitee_service.dart';
import '../services/voice_schedule_slot_planner.dart';
import '../services/pending_google_day_sync.dart';
import '../services/calendar_slot_refresh.dart';
import '../models/diary_kind.dart';
import '../models/known_google_users.dart';
import '../services/app_user_identity_store.dart';
import 'target_stats_cache.dart';
import '../utils/schedule_view_dates.dart';
import '../utils/calendar_time_range.dart';

enum TimePointStatus { onTime, late, notDone }

class BackupPreview {
  final String? exportedAt;
  final int dayCount;
  final int targetCount;
  final int categoryCount;
  final int templateCount;

  const BackupPreview({
    this.exportedAt,
    required this.dayCount,
    required this.targetCount,
    required this.categoryCount,
    required this.templateCount,
  });
}

/// An immutable full replacement used by the serialized save queue.
/// It keeps an overwrite candidate invisible to listeners until the save and
/// its final identity/revision guard both succeed.
class _ScheduleSaveSnapshot {
  const _ScheduleSaveSnapshot({
    required this.dailySlots,
    required this.giteePendingDates,
    required this.googlePendingDates,
    required this.isStillValid,
  });

  final Map<String, List<TimeSlot>> dailySlots;
  final Set<String> giteePendingDates;
  final Set<String> googlePendingDates;
  final bool Function() isStillValid;
}

enum _ScheduleSaveMode { normal, remoteViewTransition }

class _SchedulePreferencesSnapshot {
  const _SchedulePreferencesSnapshot(this.values);

  final Map<String, Object?> values;

  Map<String, dynamic> toJournalMap() => {
        for (final entry in values.entries)
          entry.key: {
            'present': entry.value != null,
            if (entry.value != null) 'value': entry.value,
          },
      };

  static _SchedulePreferencesSnapshot? fromJournalMap(dynamic raw) {
    try {
      if (raw is! Map) return null;
      final values = <String, Object?>{};
      for (final key in TimeProvider._scheduleSnapshotKeys) {
        final entry = raw[key];
        if (entry is! Map || entry['present'] is! bool) return null;
        final present = entry['present'] as bool;
        final value = entry['value'];
        if (present && value is! String && value is! List) return null;
        if (value is List && !value.every((item) => item is String)) {
          return null;
        }
        values[key] = present
            ? (value is List ? List<Object?>.from(value) : value)
            : null;
      }
      return _SchedulePreferencesSnapshot(values);
    } catch (_) {
      return null;
    }
  }
}

class _ScheduleOverwriteJournal {
  const _ScheduleOverwriteJournal({
    required this.phase,
    required this.before,
    required this.after,
  });

  static const prepared = 'prepared';
  static const committed = 'committed';

  final String phase;
  final _SchedulePreferencesSnapshot before;
  final _SchedulePreferencesSnapshot after;

  String encode() => jsonEncode({
        'version': 2,
        'phase': phase,
        'before': before.toJournalMap(),
        'after': after.toJournalMap(),
      });

  _ScheduleOverwriteJournal withPhase(String nextPhase) {
    return _ScheduleOverwriteJournal(
      phase: nextPhase,
      before: before,
      after: after,
    );
  }

  static _ScheduleOverwriteJournal? fromEncoded(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      final phase = decoded['phase'];
      if (phase is String &&
          (phase == prepared || phase == committed) &&
          decoded.containsKey('before') &&
          decoded.containsKey('after')) {
        final before = _SchedulePreferencesSnapshot.fromJournalMap(
          decoded['before'],
        );
        final after = _SchedulePreferencesSnapshot.fromJournalMap(
          decoded['after'],
        );
        if (before == null || after == null) return null;
        return _ScheduleOverwriteJournal(
          phase: phase,
          before: before,
          after: after,
        );
      }

      // d240b77 wrote only the old values at the root. Treat such a log as a
      // prepared transaction so an upgrade still rolls back safely.
      final legacy = _SchedulePreferencesSnapshot.fromJournalMap(decoded);
      if (legacy == null) return null;
      return _ScheduleOverwriteJournal(
        phase: prepared,
        before: legacy,
        after: legacy,
      );
    } catch (_) {
      return null;
    }
  }
}

class TimeProvider with ChangeNotifier {
  static const int backupVersion = 1;
  static const Color calendarImportColor = Color(0xFF78909C);
  static const String _scheduleOverwriteJournalKey =
      'schedule_overwrite_transaction_journal';
  static const Set<String> _scheduleSnapshotKeys = {
    'daily_slots',
    'pending_gitee_sync_dates',
    'pending_google_sync_dates',
    'pending_sync_dates',
  };

  /// 临时事件保留名：首页"临时"按钮分类，也是父事件视图中无归属事件的聚合项名称
  static const String temporaryCategoryName = '临时';
  Timer? _debounceTimer;
  Future<bool>? _ongoingSave;
  int _saveRequestRevision = 0;
  bool _isDisposed = false;

  DateTime _currentDate = DateTime.now();
  bool _isSyncing = false; // 添加同步锁标志，防止并发同步导致重复
  final Duration _scheduleGiteeDebounce;
  final Duration _googleCalendarDebounce;
  final bool? _googleCalendarSyncPlatformOverride;
  final bool? _googleCalendarSignedInOverride;
  final ScheduleSyncDependencies _scheduleSyncDependencies;
  final Future<bool> Function()? _saveDataOverride;
  final void Function(String key)? _scheduleSnapshotWriteObserver;
  final void Function(String phase)? _scheduleSnapshotJournalPhaseObserver;
  final Future<bool> Function()? _scheduleSnapshotJournalRemoveOverride;
  String? _lastScheduleOverwriteFailure;
  String? get lastScheduleOverwriteFailure => _lastScheduleOverwriteFailure;
  bool _scheduleOverwriteJournalCleanupPending = false;
  // Cleanup is the one phase where the committed snapshot must not be
  // followed by an identity or revision change. Public mutations reject for
  // the whole overwrite transaction; journal removal remains cleanup-only.
  bool _scheduleOverwriteCleanupInProgress = false;
  bool _scheduleIdentityMutationInProgress = false;
  bool _deferredScheduleSaveRequested = false;
  int _googleSyncGeneration = 0;

  bool get _isSchedulePersistenceBlocked =>
      !_isInitialLoadFinished ||
      _initializationFailed ||
      _isDisposed ||
      _scheduleOverwriteJournalCleanupPending ||
      _scheduleOverwriteCleanupInProgress ||
      _remoteViewTransitionInProgress ||
      _remoteViewEnabled;

  bool get _isScheduleReady =>
      _isInitialLoadFinished && !_initializationFailed && !_isDisposed;

  bool get _isScheduleIdentityReady =>
      _isScheduleReady && _scheduleUserLoadFinished;

  bool _allowScheduleMutation() {
    if (!_isScheduleReady) return false;
    if (_scheduleIdentityMutationInProgress ||
        _scheduleOverwriteInProgress ||
        _scheduleOverwriteCleanupInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      _addScheduleSyncStatus(
        _scheduleOverwriteJournalCleanupPending
            ? '覆盖日程清理未完成，修改已忽略'
            : _remoteViewTransitionInProgress
                ? '远程视图切换进行中，修改已忽略'
                : _remoteViewEnabled
                    ? '远程视图只读，修改已忽略'
                    : '覆盖拉取进行中，修改已忽略',
      );
      return false;
    }
    return true;
  }

  bool _allowScheduleIdentityMutation() {
    // The overwrite owns the selected namespace for its whole transaction.
    // Do not let an identity request mutate memory first and then race the
    // snapshot writes, publication, or journal cleanup.
    if (!_isScheduleIdentityReady || _scheduleIdentityMutationInProgress) {
      return false;
    }
    if (_scheduleOverwriteInProgress ||
        _scheduleOverwriteCleanupInProgress ||
        _scheduleOverwriteJournalCleanupPending) {
      _addScheduleSyncStatus(
        _scheduleOverwriteJournalCleanupPending
            ? '覆盖日程清理未完成，身份切换已忽略'
            : '覆盖拉取进行中，身份切换已忽略',
      );
      return false;
    }
    return _allowScheduleMutation();
  }

  bool _canContinueScheduleSync(
    String selectedUserCode, {
    bool allowRemoteViewTransition = false,
  }) {
    return _isScheduleIdentityReady &&
        !_initializationFailed &&
        !_isDisposed &&
        !_scheduleOverwriteJournalCleanupPending &&
        !_scheduleOverwriteInProgress &&
        !_scheduleIdentityMutationInProgress &&
        (allowRemoteViewTransition ||
            (!_remoteViewTransitionInProgress && !_remoteViewEnabled)) &&
        _hasSelectedScheduleUser &&
        _scheduleUser.code == selectedUserCode;
  }

  bool _allowScheduleNavigation() {
    return _isScheduleReady &&
        !_scheduleIdentityMutationInProgress &&
        !_scheduleOverwriteInProgress &&
        !_scheduleOverwriteCleanupInProgress &&
        !_scheduleOverwriteJournalCleanupPending &&
        !_remoteViewTransitionInProgress;
  }

  bool get _hasScheduleSyncInFlight =>
      _scheduleGiteeSyncing ||
      _allScheduleSyncing ||
      _allSchedulePulling ||
      _isSyncing ||
      _scheduleMergePullsInProgress > 0 ||
      _googleCalendarPullsInProgress > 0 ||
      _categoriesGiteeSyncing;

  bool _canContinueRemoteViewPersistence(int epoch) {
    return _isScheduleReady &&
        _remoteViewTransitionInProgress &&
        _remoteViewTransitionEpoch == epoch &&
        !_scheduleOverwriteInProgress &&
        !_scheduleOverwriteCleanupInProgress &&
        !_scheduleOverwriteJournalCleanupPending &&
        !_scheduleIdentityMutationInProgress;
  }

  /// 本地已改、尚未成功同步到日历的日期（dateKey 列表）
  bool _googleCalendarSyncEnabled = !isDesktopPlatform;
  bool get _supportsGoogleCalendarSync =>
      _googleCalendarSyncPlatformOverride ?? !isDesktopPlatform;
  bool get _isGoogleCalendarSignedIn =>
      _googleCalendarSignedInOverride ?? GoogleCalendarService.isSignedIn;
  bool get googleCalendarSyncEnabled =>
      _supportsGoogleCalendarSync && _googleCalendarSyncEnabled;
  bool get isWindows => isDesktopPlatform;
  bool _hasSelectedScheduleUser = !isDesktopPlatform;
  bool get hasSelectedScheduleUser => _hasSelectedScheduleUser;

  /// 是否正在查看对方日程（合并了远端数据）
  bool _remoteViewEnabled = false;
  bool get isRemoteViewEnabled => _remoteViewEnabled;
  final Map<String, String> _remoteViewBackup = {}; // dateKey → 本地 JSON 快照
  int _schedulePullRevision = 0;
  // Remote view has asynchronous save/pull phases. Claim this lock before
  // the first await so overwrite cannot pass its entry check while a toggle
  // is paused and later clear/restore the schedule behind the overwrite.
  bool _remoteViewTransitionInProgress = false;
  int _remoteViewTransitionEpoch = 0;

  /// 当前日程用户身份，从本地持久化存储加载（与打卡一致）
  DiaryKind get scheduleUser => _scheduleUser;

  String get scheduleUserCode => scheduleUser.code;

  DiaryKind _scheduleUser = DiaryKind.g;
  static const String _scheduleUserKey = 'schedule_user_kind';

  Future<void> setScheduleUser(DiaryKind kind) async {
    if (!_allowScheduleIdentityMutation()) return;
    if (_scheduleUser == kind && _hasSelectedScheduleUser) return;
    final previousKind = _scheduleUser;
    final previousHasSelectedUser = _hasSelectedScheduleUser;
    SharedPreferences? prefs;
    String? previousStoredKind;
    var persistenceNeedsRestore = false;
    _scheduleIdentityMutationInProgress = true;
    try {
      prefs = await SharedPreferences.getInstance();
      if (!_canContinueScheduleIdentityMutation()) return;
      previousStoredKind = prefs.getString(_scheduleUserKey);

      // Keep the in-memory identity and its SharedPreferences namespace
      // unchanged until the secure identity store has accepted the new kind.
      persistenceNeedsRestore = true;
      await AppUserIdentityStore.saveManualKind(kind);
      if (!_canContinueScheduleIdentityMutation()) return;
      if (!await prefs.setString(_scheduleUserKey, kind.code) ||
          !_canContinueScheduleIdentityMutation()) {
        return;
      }

      _scheduleUser = kind;
      _hasSelectedScheduleUser = true;
      persistenceNeedsRestore = false;
      notifyListeners();
      // 切换身份后拉取新身份当前日期的日程
      _pullOwnScheduleIfWindows();
      if (!_initializationFailed &&
          isDesktopPlatform &&
          pendingGiteeSyncDates.isNotEmpty) {
        unawaited(syncAllSchedulesToGitee());
      }
    } catch (e) {
      debugPrint('切换日程身份失败: $e');
    } finally {
      if (persistenceNeedsRestore) {
        _scheduleUser = previousKind;
        _hasSelectedScheduleUser = previousHasSelectedUser;
        if (prefs != null) {
          try {
            if (previousStoredKind == null) {
              await prefs.remove(_scheduleUserKey);
            } else {
              await prefs.setString(_scheduleUserKey, previousStoredKind);
            }
          } catch (e) {
            debugPrint('恢复日程身份偏好失败: $e');
          }
        }
        if (previousHasSelectedUser) {
          try {
            await AppUserIdentityStore.saveManualKind(previousKind);
          } catch (e) {
            debugPrint('恢复安全存储中的日程身份失败: $e');
          }
        } else {
          try {
            await AppUserIdentityStore.clearManualKind();
          } catch (e) {
            debugPrint('清除未提交的日程身份失败: $e');
          }
        }
      }
      _scheduleIdentityMutationInProgress = false;
    }
  }

  bool _canContinueScheduleIdentityMutation() {
    return _isScheduleIdentityReady &&
        _scheduleIdentityMutationInProgress &&
        !_scheduleOverwriteInProgress &&
        !_scheduleOverwriteCleanupInProgress &&
        !_scheduleOverwriteJournalCleanupPending;
  }

  Future<void> setGoogleCalendarSyncEnabled(bool enabled) async {
    if (!_allowScheduleMutation() || !_supportsGoogleCalendarSync) return;
    if (_googleCalendarSyncEnabled == enabled) return;
    _googleCalendarSyncEnabled = enabled;
    if (!enabled) {
      _googleSyncGeneration++;
      _debounceTimer?.cancel();
      _debounceTimer = null;
      if (!_syncStatusController.isClosed) {
        _addSyncStatus('Google 日历同步已关闭');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (!_isScheduleReady || _scheduleOverwriteCleanupInProgress) return;
    if (!await prefs.setBool('google_calendar_sync_enabled', enabled) ||
        !_isScheduleReady ||
        _scheduleOverwriteCleanupInProgress) {
      return;
    }
    notifyListeners();
    if (enabled && !_initializationFailed) {
      unawaited(_restoreGoogleInBackground());
    }
  }

  final PendingSyncState _pendingSyncState = PendingSyncState();
  Set<String> get pendingGiteeSyncDates => _pendingSyncState.giteeDates;
  Set<String> get pendingGoogleSyncDates => _pendingSyncState.googleDates;
  Set<String> get pendingSyncDates => _pendingSyncState.visibleDates(
        googleEnabled: googleCalendarSyncEnabled,
      );
  bool get hasPendingSync => pendingSyncDates.isNotEmpty;
  bool get hasPendingSyncForCurrentDate =>
      pendingSyncDates.contains(_getDateKey(_currentDate));

  // 分类展开状态持久化（以 Category ID 为 key，避免拖动排序时错位）
  Map<String, bool> _categoryExpandStates = {};
  bool _categoryExpandDirty = false; // 展开状态是否已变化，变化时才写盘

  bool getCategoryExpandState(String categoryId) {
    return _categoryExpandStates[categoryId] ?? true; // 默认展开
  }

  void setCategoryExpandState(String categoryId, bool isExpanded) {
    if (!_allowScheduleMutation()) return;
    _categoryExpandStates[categoryId] = isExpanded;
    _categoryExpandDirty = true;
    _categoriesRevision++;
    notifyListeners();
    _saveData();
  }

  // 存储模型对象 Map
  final Map<String, List<TimeSlot>> _dailySlots = {};

  // 本地数据初始加载是否已结束（无论成败都会置位，供依赖数据就绪的特性使用）
  bool _isInitialLoadFinished = false;
  // 日程身份的持久化加载晚于本地槽位加载；在此完成前禁止任何依赖
  // 当前身份的同步或切换，但保留 UI 的临时槽位展示。
  bool _scheduleUserLoadFinished = false;
  final Completer<void> _initialLoadCompleter = Completer<void>();
  bool get isInitialLoadFinished => _isInitialLoadFinished;
  bool _initializationFailed = false;
  String? _initializationFailureMessage;
  bool get hasInitializationFailure => _initializationFailed;
  String? get initializationFailureMessage => _initializationFailureMessage;

  /// 用户在 App 内删除的 Google 日历导入（按日期），不再自动拉回
  final Map<String, Set<String>> _ignoredCalendarImports = {};

  // 目标列表移至 Provider 管理
  final List<Target> _targets = [];
  List<Target> get targets => List.unmodifiable(_targets);

  // 分类列表移至 Provider 管理
  List<Category> _categories = [];
  List<Category> get categories => List.unmodifiable(_categories);

  final List<ScheduleTemplate> _templates = [];
  List<ScheduleTemplate> get templates => List.unmodifiable(_templates);
  final int _startHour = 7; // 默认从 7 点开始
  int get startHour => _startHour;

  // --- 增量保存脏标记 ---
  bool _categoriesDirty = false;
  int _categoriesRevision = 0;
  int get categoriesRevision => _categoriesRevision;
  bool _targetsDirty = false;
  int _templatesRevision = 0;
  int get templatesRevision => _templatesRevision;
  int _slotsRevision = 0;
  int get slotsRevision => _slotsRevision;
  final Set<String> _slotsDirty = {}; // 变化的日期 key
  bool _allSlotsDirty = false; // 全量脏标记（用于 _propagateLabelRename 等场景）
  bool _templatesDirty = false;
  bool _calendarDirty = false;
  bool _syncDirty = false;

  // --- 目标统计缓存 ---
  final TargetStatsCache _targetStatsCache = TargetStatsCache();
  TargetStatsCache get targetStatsCache => _targetStatsCache;

  // --- 统计缓存 ---
  String? _statsCacheKey;
  Map<String, double>? _statsCache;
  String? _occurrenceCacheKey;
  Map<String, int>? _occurrenceCache;

  // --- 标签到分类ID映射缓存 ---
  Map<String, String>? _labelCategoryIdCache;
  Map<String, Category>? _categoryIdMapCache;

  // --- 目标统计变化通知（仅在目标相关数据变化时通知） ---
  final StreamController<void> _targetStatsChangedController =
      StreamController<void>.broadcast();
  Stream<void> get targetStatsChanged => _targetStatsChangedController.stream;

  // 用于发送同步状态消息的 Stream
  final StreamController<String> _syncStatusController =
      StreamController<String>.broadcast();
  Stream<String> get syncStatusStream => _syncStatusController.stream;

  StreamSubscription<void>? _googleAuthSubscription;

  @override
  void dispose() {
    _isDisposed = true;
    _googleSyncGeneration++;
    _debounceTimer?.cancel();
    _scheduleGiteeTimer?.cancel();
    _categoriesGiteeTimer?.cancel();
    _googleAuthSubscription?.cancel();
    _syncStatusController.close();
    _scheduleGiteeSyncController?.close();
    _targetStatsChangedController.close();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_isDisposed || !_isInitialLoadFinished) return;
    super.notifyListeners();
  }

  TimeProvider({
    Duration scheduleGiteeDebounce = const Duration(seconds: 3),
    Duration googleCalendarDebounce = const Duration(seconds: 3),
    bool? googleCalendarSyncPlatformOverride,
    bool? googleCalendarSignedInOverride,
    ScheduleSyncDependencies? scheduleSyncDependencies,
    Future<bool> Function()? saveDataOverride,
    void Function(String key)? scheduleSnapshotWriteObserver,
    void Function(String phase)? scheduleSnapshotJournalPhaseObserver,
    Future<bool> Function()? scheduleSnapshotJournalRemoveOverride,
  })  : _scheduleGiteeDebounce = scheduleGiteeDebounce,
        _googleCalendarDebounce = googleCalendarDebounce,
        _googleCalendarSyncPlatformOverride =
            googleCalendarSyncPlatformOverride,
        _googleCalendarSignedInOverride = googleCalendarSignedInOverride,
        _scheduleSyncDependencies =
            scheduleSyncDependencies ?? ScheduleSyncDependencies.production(),
        _saveDataOverride = saveDataOverride,
        _scheduleSnapshotWriteObserver = scheduleSnapshotWriteObserver,
        _scheduleSnapshotJournalPhaseObserver =
            scheduleSnapshotJournalPhaseObserver,
        _scheduleSnapshotJournalRemoveOverride =
            scheduleSnapshotJournalRemoveOverride {
    if (_googleCalendarSyncPlatformOverride != null) {
      _googleCalendarSyncEnabled = _googleCalendarSyncPlatformOverride!;
    }
    _googleAuthSubscription =
        GoogleCalendarService.authStateChanges.listen((_) {
      if (!_isInitialLoadFinished || _initializationFailed || _isDisposed) {
        return;
      }
      final syncGeneration = _googleSyncGeneration;
      notifyListeners();
      unawaited(pullGoogleCalendarForDate(
        _currentDate,
        syncGeneration: syncGeneration,
      ));
    });
    _init();
  }

  void _markInitializationFailed(String message) {
    if (_isDisposed) return;
    final wasFailed = _initializationFailed;
    _initializationFailed = true;
    _initializationFailureMessage = message;
    _googleSyncGeneration++;
    _debounceTimer?.cancel();
    _scheduleGiteeTimer?.cancel();
    _categoriesGiteeTimer?.cancel();
    _debounceTimer = null;
    _scheduleGiteeTimer = null;
    _categoriesGiteeTimer = null;
    _addScheduleSyncStatus(message);
    if (!wasFailed) notifyListeners();
  }

  Future<void> _init() async {
    // 先加载本地数据并刷新 UI，避免等待 Google 静默登录阻塞首屏
    try {
      await _loadData();
    } catch (e) {
      debugPrint('初始数据加载失败: $e');
      if (!_isDisposed) {
        _markInitializationFailed('本地日程恢复失败，请检查本地数据后重试');
      }
    } finally {
      // 无论加载成败都标记加载已结束，避免依赖此标志的特性（如那年今日弹窗）被静默跳过
      if (!_isDisposed) {
        _isInitialLoadFinished = true;
        notifyListeners();
      }
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
    }
    if (_isDisposed || _initializationFailed) return;
    await _refreshHomeWidget();
    if (_isDisposed || _initializationFailed) return;
    // 从本地持久化存储直接加载用户身份（不联网，瞬间完成）
    await _loadScheduleUserFromStore();
    if (_isDisposed || _initializationFailed) return;
    // 拉取当前身份的分类（事件/子事件）到本地（安卓与 Windows 都执行）
    unawaited(_pullCategoriesFromGitee());
    // Windows 上拉取当前日期自己的日程，补上安卓端推送的数据
    _pullOwnScheduleIfWindows();
    // 后台恢复 Google 日历会话（不阻塞）
    unawaited(GoogleCalendarService.restoreSignIn(background: true));
  }

  Future<void> _loadScheduleUserFromStore() async {
    if (isDesktopPlatform) {
      final manualKind = await AppUserIdentityStore.loadManualKind();
      if (_initializationFailed || _isDisposed) return;
      if (manualKind != null) {
        _scheduleUser = manualKind;
        _hasSelectedScheduleUser = true;
      }
      _scheduleUserLoadFinished = true;
      notifyListeners();
      return;
    }
    final identity = await AppUserIdentityStore.load();
    if (_initializationFailed || _isDisposed) return;
    if (identity != null) {
      final nickname = KnownGoogleUsers.nicknameFor(identity.email);
      if (nickname == '乖乖') {
        _scheduleUser = DiaryKind.g;
      } else if (nickname == '晶晶') {
        _scheduleUser = DiaryKind.j;
      }
    }
    _scheduleUserLoadFinished = true;
  }

  Future<void> _restoreGoogleInBackground() async {
    if (_isDisposed ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _scheduleOverwriteJournalCleanupPending ||
        !_googleCalendarSyncEnabled) {
      return;
    }
    final syncGeneration = _googleSyncGeneration;
    await GoogleCalendarService.restoreSignIn(background: true);
    if (_isDisposed ||
        _initializationFailed ||
        _scheduleOverwriteJournalCleanupPending ||
        syncGeneration != _googleSyncGeneration ||
        !_googleCalendarSyncEnabled) {
      return;
    }
    if (_isGoogleCalendarSignedIn) {
      notifyListeners();
      if (_isDisposed ||
          _initializationFailed ||
          syncGeneration != _googleSyncGeneration) {
        return;
      }
      await pullGoogleCalendarForCurrentDate();
    } else if (GoogleCalendarService.needsCalendarReconnect) {
      notifyListeners();
    }
  }

  DateTime get currentDate => _currentDate;

  final Map<String, List<List<TimeSlot>>> _undoStacks = {};
  final int _maxStackSize = 20; // 最大支持撤回 20 步

  List<TimeSlot> get slots {
    if (!_isInitialLoadFinished) return _generateInitialSlots();
    if (!_isScheduleReady) return const <TimeSlot>[];
    String dateKey = _getDateKey(_currentDate);
    return _dailySlots.putIfAbsent(dateKey, () => _generateInitialSlots());
  }

  /// 获取指定日期的时间块列表
  List<TimeSlot>? getSlotsForDate(String dateKey) {
    if (!_isScheduleReady) return null;
    return _dailySlots[dateKey];
  }

  /// 获取（必要时生成）指定日期的 144 槽位，供双列视图等按日期渲染使用。
  /// 空槽不会被标记为 dirty，不会触发落盘。
  List<TimeSlot> slotsForDate(DateTime date) {
    if (!_isInitialLoadFinished) return _generateInitialSlots();
    if (!_isScheduleReady) return const <TimeSlot>[];
    return _dailySlots.putIfAbsent(
        _getDateKey(date), () => _generateInitialSlots());
  }

  // 生成一天 144 个初始槽位对象
  List<TimeSlot> _generateInitialSlots() {
    return List.generate(144, (index) {
      int h = index ~/ 6;
      int m10 = index % 6;
      return TimeSlot(hour: h, minute10: m10, recorded: false);
    });
  }

  String _getDateKey(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  /// 将日期 key 规范化为 yyyy-MM-dd 格式。
  /// 兼容旧版本不补零的存储格式（如 "2024-7-24" → "2024-07-24"），
  /// 避免升级后旧数据读取不到。
  static String _normalizeDateKey(String key) {
    final parts = key.split('-');
    if (parts.length == 3) {
      final year = parts[0];
      final month = int.tryParse(parts[1]);
      final day = int.tryParse(parts[2]);
      if (month != null && day != null) {
        final normalized =
            '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
        if (normalized != key) return normalized;
      }
    }
    return key;
  }

  /// 安全解析 JSON 中的整数，避免 `as int` 对 null/非数字值崩溃
  static int? _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void previousDay() {
    if (!_allowScheduleNavigation()) return;
    _currentDate = _currentDate.subtract(const Duration(days: 1));
    notifyListeners();
    _refreshHomeWidget();
    pullGoogleCalendarForCurrentDate();
    _pullOwnScheduleIfWindows();
  }

  void nextDay() {
    if (!_allowScheduleNavigation()) return;
    _currentDate = _currentDate.add(const Duration(days: 1));
    notifyListeners();
    _refreshHomeWidget();
    pullGoogleCalendarForCurrentDate();
    _pullOwnScheduleIfWindows();
  }

  void goToDate(DateTime date) {
    if (!_allowScheduleNavigation()) return;
    _currentDate = DateTime(date.year, date.month, date.day);
    notifyListeners();
    _refreshHomeWidget();
    pullGoogleCalendarForCurrentDate();
    _pullOwnScheduleIfWindows();
  }

  /// Windows 上切日/初始化后的日程拉取：
  /// 远程视图开启时拉取对方三列数据；否则拉取当前日期"自己身份"的日程并合并（union），
  /// 解决安卓端推送后 Windows 本地无数据看不到自己日程的问题。
  /// 拉取失败静默，不打断用户操作。
  void _pullOwnScheduleIfWindows() {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        !isDesktopPlatform) {
      return;
    }
    if (!_hasSelectedScheduleUser) return;
    final requestRevision = ++_schedulePullRevision;
    if (_remoteViewEnabled) {
      _pullRemoteViewSchedules(requestRevision: requestRevision);
    } else {
      for (final date in scheduleDatesForView(
        _currentDate,
        desktop: isDesktopPlatform,
      )) {
        unawaited(pullScheduleFromGitee(
          date: date,
          requestRevision: requestRevision,
        ));
      }
    }
  }

  /// 远程视图下：对当前三列日期备份本地（仅首次访问的日期）并拉取对方数据。
  /// 远程视图期间切换日期时，由 [_pullOwnScheduleIfWindows] 调用。
  void _pullRemoteViewSchedules({int? requestRevision}) {
    final otherCode = _scheduleUser.code == 'g' ? 'j' : 'g';
    for (final d in _getRemoteViewDates()) {
      _backupAndClearDay(_getDateKey(d));
      unawaited(pullScheduleFromGitee(
        userCode: otherCode,
        date: d,
        requestRevision: requestRevision,
        allowRemoteViewTransition: true,
      ));
    }
    _markAllSlotsDirty();
    notifyListeners();
  }

  /// 备份一天的本地数据（仅首次，避免覆盖已备份的本地快照）并清空当天槽位。
  void _backupAndClearDay(String dateKey) {
    if (!_remoteViewBackup.containsKey(dateKey)) {
      final localSlots = _dailySlots[dateKey] ?? _generateInitialSlots();
      _remoteViewBackup[dateKey] =
          json.encode(_serializeRecordedSlots(localSlots));
    }
    _clearDaySlots(_dailySlots.putIfAbsent(dateKey, _generateInitialSlots));
  }

  void toggleSlot(int index) {
    if (!_allowScheduleMutation() || _remoteViewEnabled) {
      return; // 恢复失败或远程视图只读，禁止编辑本地数据
    }
    _saveSnapshot();
    List<TimeSlot> currentSlots = slots;
    currentSlots[index].recorded = !currentSlots[index].recorded;
    if (currentSlots[index].recorded) {
      currentSlots[index].modifiedAt = DateTime.now();
      currentSlots[index].deletedAt = null;
    } else {
      currentSlots[index].deletedAt = DateTime.now();
    }
    final dateKey = _getDateKey(_currentDate);
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    _markPendingSync(dateKey);
    _saveData();
    notifyListeners();
    _addTargetStatsChanged(); // 通知目标统计变化
  }

  void clearAll() {
    if (!_allowScheduleMutation() || _remoteViewEnabled) return;
    _saveSnapshot();
    final dateKey = _getDateKey(_currentDate);
    final daySlots = _dailySlots.putIfAbsent(dateKey, _generateInitialSlots);
    for (int i = 0; i < daySlots.length; i++) {
      if (daySlots[i].recorded) {
        // 自记录槽写墓碑，保证整日清空跨设备可传播；
        // 日历块不写墓碑（其显示由 Google pull + 忽略列表管理）
        _clearSlotAt(daySlots, i, markDeleted: !daySlots[i].isFromCalendar);
      }
    }
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    _markPendingSync();
    _saveData();
    notifyListeners();
    _addTargetStatsChanged(); // 通知目标统计变化
    _scheduleCalendarSync();
  }

  /// 清理超过最大保留天数的旧日期撤销栈（防止内存无限增长）
  static const int _maxUndoDayCount = 7;

  void _cleanupOldUndoStacks() {
    if (_undoStacks.length <= _maxUndoDayCount) return;
    final now = DateTime.now();
    final threshold = now.subtract(Duration(days: _maxUndoDayCount));
    _undoStacks.removeWhere((dateKey, _) {
      final parts = dateKey.split('-');
      if (parts.length != 3) return true; // 格式异常的也清理
      final year = int.tryParse(parts[0]);
      final month = int.tryParse(parts[1]);
      final day = int.tryParse(parts[2]);
      if (year == null || month == null || day == null) return true;
      final date = DateTime(year, month, day);
      return date
          .isBefore(DateTime(threshold.year, threshold.month, threshold.day));
    });
  }

  void _saveSnapshot([String? dateKey]) {
    final key = dateKey ?? _getDateKey(_currentDate);
    _lastEditedDateKey = key;
    _undoStacks.putIfAbsent(key, () => []);

    _cleanupOldUndoStacks();

    // 深度拷贝当前的 slots
    final daySlots =
        _dailySlots.putIfAbsent(key, () => _generateInitialSlots());
    List<TimeSlot> snapshot = daySlots
        .map((s) => TimeSlot(
              hour: s.hour,
              minute10: s.minute10,
              recorded: s.recorded,
              label: s.label,
              categoryId: s.categoryId,
              color: s.color,
              isFromCalendar: s.isFromCalendar,
              calendarEventId: s.calendarEventId,
              modifiedAt: s.modifiedAt,
              deletedAt: s.deletedAt,
            ))
        .toList();

    _undoStacks[key]!.add(snapshot);

    // 如果超过最大步数，移除最早的一条
    if (_undoStacks[key]!.length > _maxStackSize) {
      _undoStacks[key]!.removeAt(0);
    }
  }

  void undo() {
    if (!_allowScheduleMutation() || _remoteViewEnabled) return;
    final dateKey = _lastEditedDateKey ?? _getDateKey(_currentDate);
    if (_undoStacks[dateKey] != null && _undoStacks[dateKey]!.isNotEmpty) {
      _dailySlots[dateKey] = _undoStacks[dateKey]!.removeLast();
      _targetStatsCache.invalidateDate(dateKey);
      _markSlotsDirty(dateKey);
      _markPendingSync(dateKey);
      _saveData();
      notifyListeners();
      if (dateKey == _getDateKey(_currentDate)) {
        _scheduleCalendarSync();
      }
    }
  }

  void assignCategoryToSlots(Set<int> indices, Category category,
      {String? subLabel, DateTime? date}) {
    if (!_allowScheduleMutation() || _remoteViewEnabled) return;
    if (indices.isEmpty) return;

    // 未指定日期时维持原有行为（操作当前日期，走完整同步链路）
    final targetDate = date ?? _currentDate;
    final dateKey = _getDateKey(targetDate);
    final daySlots = slotsForDate(targetDate);

    _saveSnapshot(dateKey);

    final label = subLabel ?? category.name;
    final now = DateTime.now();
    for (var index in indices) {
      daySlots[index].recorded = true;
      daySlots[index].label = label;
      daySlots[index].categoryId = category.id;
      daySlots[index].color = category.color;
      daySlots[index].isFromCalendar = false;
      daySlots[index].calendarEventId = null;
      daySlots[index].modifiedAt = now;
      daySlots[index].deletedAt = null;
    }
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    // 编辑当前日期走完整同步链路；三列视图的其他日期也要同步到对应 Gitee 文件。
    if (date == null || dateKey == _getDateKey(_currentDate)) {
      _markPendingSync();
      _scheduleCalendarSync();
    } else {
      _markPendingSync(dateKey);
    }
    _saveData();
    notifyListeners();
    _addTargetStatsChanged(); // 通知目标统计变化
  }

  /// 应用语音解析出的日程草稿。
  ///
  /// 已匹配事件时沿用已有分类 ID；未匹配时只写入一次性标签，不把临时事件
  /// 添加到分类列表。真正的槽位写入仍复用 [assignCategoryToSlots]，因此会
  /// 进入同一套撤销、持久化和同步流程。
  VoiceScheduleApplyResult applyVoiceSchedule(
    VoiceScheduleDraft draft, {
    VoiceScheduleConflictMode mode = VoiceScheduleConflictMode.fillEmptyOnly,
  }) {
    if (!_allowScheduleMutation() || _remoteViewEnabled) {
      return const VoiceScheduleApplyResult(
        appliedSlotCount: 0,
        conflictCount: 0,
      );
    }

    final targetDate = DateTime(
      draft.date.year,
      draft.date.month,
      draft.date.day,
    );
    final daySlots = slotsForDate(targetDate);
    final plan = VoiceScheduleSlotPlanner.plan(
      slots: daySlots,
      draft: draft,
      mode: mode,
    );
    if (plan.indicesToApply.isEmpty) {
      return VoiceScheduleApplyResult(
        appliedSlotCount: 0,
        conflictCount: plan.conflictCount,
      );
    }

    final matchedCategory = draft.categoryId == null
        ? null
        : _categories.cast<Category?>().firstWhere(
              (category) => category?.id == draft.categoryId,
              orElse: () => null,
            );
    final category = matchedCategory == null
        ? Category(
            name: draft.label,
            color: const Color(0xFF9E9E9E),
          )
        : Category(
            id: matchedCategory.id,
            name: draft.label,
            color: matchedCategory.color,
          );

    assignCategoryToSlots(
      plan.indicesToApply,
      category,
      date: targetDate,
    );
    return VoiceScheduleApplyResult(
      appliedSlotCount: plan.indicesToApply.length,
      conflictCount: plan.conflictCount,
    );
  }

  /// 是否已登录可同步的 Google 日历账号
  bool get canSyncToCalendar => GoogleCalendarService.isSignedIn;

  /// 走防抖自动同步（待同步标记由调用方在 _saveData 前写入）
  void _scheduleCalendarSync() {
    synchronizeCalendar(delay: true);
  }

  // --- Gitee 日程同步 ---

  StreamController<String>? _scheduleGiteeSyncController;
  Stream<String> get scheduleGiteeSyncStream {
    _scheduleGiteeSyncController ??= StreamController<String>.broadcast();
    return _scheduleGiteeSyncController!.stream;
  }

  /// 安全地向 scheduleGiteeSyncController 发送状态消息
  void _addScheduleSyncStatus(String message) {
    if (_isDisposed) return;
    final c = _scheduleGiteeSyncController;
    if (c != null && !c.isClosed) c.add(message);
  }

  void _addSyncStatus(String message) {
    if (_isDisposed || _syncStatusController.isClosed) return;
    _syncStatusController.add(message);
  }

  void _addTargetStatsChanged() {
    if (_isDisposed || _targetStatsChangedController.isClosed) return;
    _targetStatsChangedController.add(null);
  }

  Timer? _scheduleGiteeTimer;
  bool _scheduleGiteeSyncing = false;
  bool _scheduleOverwriteInProgress = false;
  int _scheduleMergePullsInProgress = 0;
  int _googleCalendarPullsInProgress = 0;
  final Set<String> _pendingScheduleGiteeDateKeys = {};
  final Map<String, int> _scheduleGiteeDateRevisions = {};
  String? _lastEditedDateKey;
  bool get hasPendingScheduleGiteeUpload =>
      _pendingScheduleGiteeDateKeys.isNotEmpty;

  bool get _isAnyScheduleSyncBlocked =>
      _initializationFailed ||
      !_scheduleUserLoadFinished ||
      _scheduleIdentityMutationInProgress ||
      _scheduleOverwriteJournalCleanupPending ||
      _scheduleGiteeSyncing ||
      _allScheduleSyncing ||
      _allSchedulePulling ||
      _isSyncing ||
      _scheduleOverwriteInProgress ||
      _remoteViewTransitionInProgress ||
      _remoteViewEnabled ||
      _scheduleMergePullsInProgress > 0 ||
      _googleCalendarPullsInProgress > 0 ||
      _categoriesGiteeSyncing;

  /// 标记当前日期需要同步到 Gitee（带 3 秒防抖）。
  /// [dateKey] 捕获目标日期，避免防抖期间切换日期推错日期。
  /// 多日期编辑时保留所有待同步日期，避免后一次编辑取消前一次编辑。
  void _markScheduleGiteePending([String? dateKey]) {
    if (!_isScheduleReady ||
        _scheduleOverwriteJournalCleanupPending ||
        _scheduleOverwriteInProgress ||
        _scheduleOverwriteCleanupInProgress ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      return;
    }
    final target = dateKey ?? _getDateKey(_currentDate);
    _pendingScheduleGiteeDateKeys.add(target);
    _scheduleGiteeDateRevisions[target] =
        (_scheduleGiteeDateRevisions[target] ?? 0) + 1;
    _scheduleGiteeTimer?.cancel();
    _scheduleGiteeTimer = Timer(_scheduleGiteeDebounce, () {
      _scheduleGiteeTimer = null;
      unawaited(_flushPendingScheduleGiteeSync());
    });
  }

  Future<void> _flushPendingScheduleGiteeSync() async {
    if (!_isScheduleReady) return;
    if (_scheduleOverwriteJournalCleanupPending) return;
    if (_pendingScheduleGiteeDateKeys.isEmpty) return;
    if (_isAnyScheduleSyncBlocked) {
      _scheduleGiteeTimer = Timer(const Duration(milliseconds: 100), () {
        _scheduleGiteeTimer = null;
        unawaited(_flushPendingScheduleGiteeSync());
      });
      return;
    }

    final targets = List<String>.from(_pendingScheduleGiteeDateKeys);
    for (final target in targets) {
      await syncScheduleToGitee(dateKey: target);
    }
  }

  /// 推送指定日期日程到 Gitee（每人独立文件）
  Future<void> syncScheduleToGitee({String? dateKey}) async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _isDisposed ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress) {
      return;
    }
    if (_remoteViewEnabled) {
      // 远程视图下本地是对方数据，禁止推送覆盖自己的文件
      _addScheduleSyncStatus('远程视图下不推送');
      return;
    }
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return;
    }
    if (_scheduleOverwriteInProgress || _remoteViewTransitionInProgress) return;
    final effectiveDateKey = dateKey ?? _getDateKey(_currentDate);
    final syncRevision = _scheduleGiteeDateRevisions[effectiveDateKey] ?? 0;
    final selectedUserCode = _scheduleUser.code;
    if (_isAnyScheduleSyncBlocked) {
      return;
    }
    _scheduleGiteeSyncing = true;
    try {
      final token = await _scheduleSyncDependencies.loadToken();
      if (!_canContinueScheduleSync(selectedUserCode) ||
          token == null ||
          token.isEmpty) {
        _addScheduleSyncStatus('未配置同步 Token');
        _addSyncStatus("未配置同步 Token");
        return;
      }

      final slots = _dailySlots[effectiveDateKey] ??= _generateInitialSlots();

      _addScheduleSyncStatus('同步中...');
      if (!_syncStatusController.isClosed) {
        _addSyncStatus("SYNCING");
      }
      final ok = await _pushScheduleDay(
        effectiveDateKey,
        slots,
        userCode: selectedUserCode,
        token: token,
      );
      if (!_canContinueScheduleSync(selectedUserCode)) return;
      if (ok) {
        _addScheduleSyncStatus('已同步');
        if ((_scheduleGiteeDateRevisions[effectiveDateKey] ?? 0) ==
            syncRevision) {
          _pendingScheduleGiteeDateKeys.remove(effectiveDateKey);
          _clearPendingGiteeForDate(effectiveDateKey);
        }
        if (!_syncStatusController.isClosed) {
          _addSyncStatus("日程同步成功");
        }
        Future.delayed(const Duration(seconds: 3), () {
          _addScheduleSyncStatus('');
        });
      } else {
        _addScheduleSyncStatus('同步失败');
        if (!_syncStatusController.isClosed) {
          _addSyncStatus("日程同步失败");
        }
      }
    } catch (e) {
      _addScheduleSyncStatus('同步失败: $e');
      if (!_syncStatusController.isClosed) {
        _addSyncStatus("日程同步失败: $e");
      }
    } finally {
      _scheduleGiteeSyncing = false;
      if (!_syncStatusController.isClosed) {
        _addSyncStatus("IDLE");
      }
    }
  }

  /// 推送单个日期日程到 Gitee：先拉取远端 → 槽位级"后写覆盖"合并 → 推送。
  /// 成功后把合并结果写回本地，保证本地与远端一致。
  Future<bool> _pushScheduleDay(
    String dateKey,
    List<TimeSlot> slots, {
    String? userCode,
    String? token,
  }) async {
    return _pushScheduleDayForUser(
      dateKey,
      slots,
      userCode: userCode ?? _scheduleUser.code,
      token: token,
    );
  }

  Future<bool> _pushScheduleDayForUser(
    String dateKey,
    List<TimeSlot> slots, {
    required String userCode,
    String? token,
  }) async {
    if (!_canContinueScheduleSync(userCode)) return false;
    final resolvedToken = token ?? await _scheduleSyncDependencies.loadToken();
    if (!_canContinueScheduleSync(userCode) ||
        resolvedToken == null ||
        resolvedToken.isEmpty) {
      return false;
    }

    final localEntries = _serializeRecordedSlots(slots);

    final userLabel = userCode == DiaryKind.g.code ? '乖乖' : '晶晶';

    // 1) 拉取远端
    final pullDay = _scheduleSyncDependencies.pullDay;
    final pullResult = await pullDay(
      token: resolvedToken,
      dateKey: dateKey,
      userCode: userCode,
    );
    if (!_canContinueScheduleSync(userCode)) return false;
    final remoteContent = pullResult.success ? pullResult.content : null;

    // 2) 合并（后写覆盖：同槽 ts 大者胜，仅一侧有则保留）
    final remote = parseScheduleContent(remoteContent);
    final merged = scheduleEntriesForPush(
      localEntries: localEntries,
      remoteEntries: remote.slots,
    );

    // 3) 生成差异描述（对比远端原内容与合并结果）
    final commitMessage = _buildScheduleDiffMessage(
      userLabel,
      dateKey,
      remoteContent,
      merged,
    );

    // 4) 推送合并结果（新格式包装）
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final content = json.encode({
      'updated_at': nowMs,
      'slots': merged,
    });

    final pushDay =
        _scheduleSyncDependencies.pushDay ?? ScheduleGiteeService.pushSchedule;
    final result = await pushDay(
      token: resolvedToken,
      dateKey: dateKey,
      userCode: userCode,
      content: content,
      commitMessage: commitMessage,
    );
    if (!_canContinueScheduleSync(userCode) || !result.success) return false;

    // 5) 将合并结果写回本地（含远端更新的槽位），保证本地 == 远端。
    //    注意：拉取远端期间用户可能已继续编辑本地，写回前用最新本地
    //    状态再做一次"后写覆盖"合并，避免把同步期间的新修改覆盖回旧数据。
    final latestLocal = _serializeRecordedSlots(slots);
    final finalEntries = mergeScheduleSlots(
      localEntries: latestLocal,
      remoteEntries: merged,
    );
    _applyScheduleEntriesToSlots(slots, finalEntries);
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    final saved = await _saveData();
    if (!_canContinueScheduleSync(userCode) || !saved) return false;
    notifyListeners();
    return true;
  }

  /// 将合并后的槽位 entries 应用到本地 slots（ts → modifiedAt）
  void _applyScheduleEntriesToSlots(
      List<TimeSlot> slots, List<Map<String, dynamic>> entries) {
    for (final s in slots) {
      s.recorded = false;
      s.label = null;
      s.categoryId = null;
      s.color = null;
      s.isFromCalendar = false;
      s.calendarEventId = null;
      s.modifiedAt = null;
      s.deletedAt = null;
    }
    for (final e in entries) {
      final idx = _parseInt(e['i']);
      if (idx == null || idx < 0 || idx >= slots.length) continue;
      if (e['del'] == true) {
        // 删除墓碑：槽位保持清空，仅记录删除时间
        slots[idx].isFromCalendar = e['fc'] == true;
        final delTs = _parseInt(e['ts']);
        if (delTs != null && delTs > 0) {
          slots[idx].deletedAt = DateTime.fromMillisecondsSinceEpoch(delTs);
        }
        continue;
      }
      slots[idx].recorded = true;
      slots[idx].label = e['l'] as String?;
      slots[idx].categoryId = e['cid'] as String?;
      final colorVal = _parseInt(e['c']);
      if (colorVal != null) slots[idx].color = Color(colorVal);
      if (e['fc'] == true) slots[idx].isFromCalendar = true;
      if (e['eid'] != null) slots[idx].calendarEventId = e['eid'] as String?;
      final ts = _parseInt(e['ts']);
      if (ts != null && ts > 0) {
        slots[idx].modifiedAt = DateTime.fromMillisecondsSinceEpoch(ts);
      }
    }
  }

  bool _allScheduleSyncing = false;
  bool _allSchedulePulling = false;

  // --- 分类（事件/子事件）跨端同步 ---
  Timer? _categoriesGiteeTimer;
  bool _categoriesGiteeSyncing = false;

  /// 分类删除墓碑：id → 删除时间戳（毫秒）
  final Map<String, int> _deletedCategories = {};

  /// 分类文档最后修改时间（毫秒），用于合并顺序基准与首次同步判断
  int _categoriesDocUpdatedAt = 0;

  /// 分类修改发生时归属的身份（捕获当前 scheduleUser.code，避免切身份后错写）
  String _categoriesUserCode = '';

  /// 全量同步所有日期的日程到 Gitee
  Future<void> syncAllSchedulesToGitee() async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _isDisposed ||
        _scheduleIdentityMutationInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress) {
      return;
    }
    if (_remoteViewEnabled) {
      _addScheduleSyncStatus('远程视图下不推送');
      return;
    }
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return;
    }
    if (_scheduleOverwriteInProgress ||
        _allScheduleSyncing ||
        _allSchedulePulling) {
      return;
    }
    _allScheduleSyncing = true;
    final selectedUserCode = _scheduleUser.code;
    // 取消可能正在等待的当日自动同步
    _scheduleGiteeTimer?.cancel();
    try {
      final token = await _scheduleSyncDependencies.loadToken();
      if (!_canContinueScheduleSync(selectedUserCode) ||
          token == null ||
          token.isEmpty) {
        _addScheduleSyncStatus('未配置同步 Token');
        return;
      }

      // 收集所有有记录的日期
      final dateKeys = <String>{};
      for (final entry in _dailySlots.entries) {
        if (entry.value.any((s) => s.recorded)) {
          dateKeys.add(entry.key);
        }
      }
      dateKeys.addAll(pendingGiteeSyncDates);
      dateKeys.addAll(_pendingScheduleGiteeDateKeys);

      if (dateKeys.isEmpty) {
        _addScheduleSyncStatus('无日程');
        return;
      }

      final sortedDateKeys = dateKeys.toList()..sort();
      final total = sortedDateKeys.length;
      var done = 0;
      for (final dateKey in sortedDateKeys) {
        if (!_canContinueScheduleSync(selectedUserCode)) return;
        final syncRevision = _scheduleGiteeDateRevisions[dateKey] ?? 0;
        final slots = _dailySlots[dateKey] ?? _generateInitialSlots();
        _addScheduleSyncStatus('同步中 ${done + 1}/$total...');
        final ok = await _pushScheduleDay(
          dateKey,
          slots,
          userCode: selectedUserCode,
          token: token,
        );
        if (!_canContinueScheduleSync(selectedUserCode)) return;
        if (ok) {
          done++;
          if ((_scheduleGiteeDateRevisions[dateKey] ?? 0) == syncRevision) {
            _pendingSyncState.clearGitee(dateKey);
            _pendingScheduleGiteeDateKeys.remove(dateKey);
          }
        }
      }

      _syncDirty = true;
      final saved = await _saveData();
      if (!_canContinueScheduleSync(selectedUserCode) || !saved) return;
      notifyListeners();

      if (done == total) {
        _addScheduleSyncStatus('全部同步完成 ($total 天)');
      } else {
        _addScheduleSyncStatus('同步完成 $done/$total');
      }
      Future.delayed(const Duration(seconds: 3), () {
        _addScheduleSyncStatus('');
      });
    } catch (e) {
      _addScheduleSyncStatus('全量同步失败: $e');
    } finally {
      _allScheduleSyncing = false;
    }
  }

  /// 从 Gitee 拉取当前用户所有日期的日程，逐日双向合并后统一落盘。
  Future<void> pullAllSchedulesFromGitee() async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _isDisposed ||
        _scheduleIdentityMutationInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress) {
      return;
    }
    if (_remoteViewEnabled) {
      _addScheduleSyncStatus('远程视图下不拉取');
      return;
    }
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return;
    }
    if (_scheduleOverwriteInProgress ||
        _allSchedulePulling ||
        _allScheduleSyncing) {
      return;
    }
    _allSchedulePulling = true;
    final selectedUserCode = _scheduleUser.code;
    // 取消等待中的当日自动推送，避免与全量拉取并发
    _scheduleGiteeTimer?.cancel();
    try {
      final token = await _scheduleSyncDependencies.loadToken();
      if (!_canContinueScheduleSync(selectedUserCode) ||
          token == null ||
          token.isEmpty) {
        _addScheduleSyncStatus('未配置同步 Token');
        return;
      }

      // 1) 列出远端当前用户所有日程文件
      final listResult = await _scheduleSyncDependencies.listPaths(
        token: token,
        userCode: selectedUserCode,
      );
      if (!_canContinueScheduleSync(selectedUserCode) || !listResult.success) {
        _addScheduleSyncStatus(listResult.error ?? '读取远端日程列表失败');
        return;
      }

      // 2) 从 path 提取 dateKey 并规范化（兼容旧格式），去重排序
      final dateKeys = <String>[];
      for (final path in listResult.pathShaMap.keys) {
        final fileName = path.split('/').last;
        if (!fileName.endsWith('.json')) continue;
        final raw = fileName.substring(0, fileName.length - '.json'.length);
        final normalized = _normalizeDateKey(raw);
        if (!dateKeys.contains(normalized)) dateKeys.add(normalized);
      }
      dateKeys.sort();

      if (dateKeys.isEmpty) {
        _addScheduleSyncStatus('远端无日程');
        Future.delayed(const Duration(seconds: 3), () {
          _addScheduleSyncStatus('');
        });
        return;
      }

      // 3) 逐日拉取并双向合并（单日失败不中断整体）
      final total = dateKeys.length;
      var done = 0;
      for (final dateKey in dateKeys) {
        if (!_canContinueScheduleSync(selectedUserCode)) return;
        _addScheduleSyncStatus('拉取中 ${done + 1}/$total...');
        final ok = await _pullScheduleDayFromGitee(
          token,
          dateKey,
          userCode: selectedUserCode,
        );
        if (!_canContinueScheduleSync(selectedUserCode)) return;
        if (ok) done++;
      }

      // 4) 全部完成后统一落盘 + 通知（避免逐日保存）
      if (done > 0) {
        final saved = await _saveData();
        if (!_canContinueScheduleSync(selectedUserCode) || !saved) return;
        notifyListeners();
      }

      if (done == total) {
        _addScheduleSyncStatus('全部拉取完成 ($total 天)');
      } else if (done > 0) {
        _addScheduleSyncStatus('拉取完成 $done/$total');
      } else {
        _addScheduleSyncStatus('拉取失败');
      }
      Future.delayed(const Duration(seconds: 3), () {
        _addScheduleSyncStatus('');
      });
    } catch (e) {
      _addScheduleSyncStatus('全量拉取失败: $e');
    } finally {
      _allSchedulePulling = false;
    }
  }

  Future<bool> overwriteAllSchedulesFromGitee() async {
    if (_isDisposed) return false;
    _lastScheduleOverwriteFailure = null;
    if (!_isInitialLoadFinished) {
      return _rejectScheduleOverwrite('覆盖拉取未开始：本地日程仍在加载');
    }
    if (!_scheduleUserLoadFinished) {
      return _rejectScheduleOverwrite('覆盖拉取未开始：日程身份仍在加载');
    }
    if (_initializationFailed) {
      return _rejectScheduleOverwrite(
        _initializationFailureMessage ?? '覆盖拉取未开始：本地日程恢复失败',
      );
    }
    if (_scheduleOverwriteJournalCleanupPending) {
      return _rejectScheduleOverwrite('覆盖拉取未开始：上一次提交清理尚未完成');
    }
    if (_remoteViewEnabled) {
      return _rejectScheduleOverwrite('覆盖拉取未开始：当前正在查看对方日程');
    }
    if (_remoteViewTransitionInProgress) {
      return _rejectScheduleOverwrite('覆盖拉取未开始：远程视图切换进行中');
    }
    if (!_hasSelectedScheduleUser) {
      return _rejectScheduleOverwrite('覆盖拉取未开始：请先选择身份');
    }
    if (_scheduleIdentityMutationInProgress) {
      return _rejectScheduleOverwrite('覆盖拉取未开始：身份切换进行中');
    }
    if (_scheduleOverwriteInProgress ||
        _scheduleGiteeSyncing ||
        _allScheduleSyncing ||
        _allSchedulePulling ||
        _isSyncing ||
        _scheduleMergePullsInProgress > 0 ||
        _googleCalendarPullsInProgress > 0) {
      return _rejectScheduleOverwrite('覆盖拉取未开始：已有日程同步任务');
    }

    final selectedUserCode = _scheduleUser.code;
    _scheduleOverwriteInProgress = true;
    _googleSyncGeneration++;
    _scheduleGiteeTimer?.cancel();
    _scheduleGiteeTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final startSlotsRevision = _slotsRevision;

    bool overwriteIsStillValid() =>
        _isScheduleIdentityReady &&
        !_initializationFailed &&
        !_scheduleOverwriteJournalCleanupPending &&
        !_scheduleIdentityMutationInProgress &&
        !_remoteViewTransitionInProgress &&
        _hasSelectedScheduleUser &&
        _scheduleUser.code == selectedUserCode;
    var succeeded = false;

    try {
      _addScheduleSyncStatus('覆盖拉取中...');
      final token = await _scheduleSyncDependencies.loadToken();
      if (!overwriteIsStillValid() || token == null || token.isEmpty) {
        _lastScheduleOverwriteFailure = '覆盖拉取未开始或失败，请稍后重试';
        return false;
      }

      final listResult = await _scheduleSyncDependencies.listPaths(
        token: token,
        userCode: selectedUserCode,
      );
      if (!overwriteIsStillValid() || !listResult.success) return false;

      final canonicalPaths = listResult.pathShaMap.keys.where((path) {
        return ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
          path,
          userCode: selectedUserCode,
        );
      }).toList()
        ..sort();

      final contentsByPath = <String, String>{};
      for (final path in canonicalPaths) {
        final dateKey = ScheduleOverwriteSnapshot.dateKeyFromCanonicalPath(
          path,
          userCode: selectedUserCode,
        );
        if (dateKey == null) continue;
        if (!overwriteIsStillValid()) return false;
        final pullResult = await _scheduleSyncDependencies.pullDay(
          token: token,
          dateKey: dateKey,
          userCode: selectedUserCode,
        );
        if (!overwriteIsStillValid() ||
            !pullResult.success ||
            pullResult.content == null ||
            pullResult.content!.trim().isEmpty ||
            pullResult.sha == null ||
            pullResult.sha != listResult.pathShaMap[path]) {
          return false;
        }
        contentsByPath[path] = pullResult.content!;
      }

      final snapshot = ScheduleOverwriteSnapshot.fromRemoteFiles(
        userCode: selectedUserCode,
        contentsByPath: contentsByPath,
      );
      if (!snapshot.isValid) return false;

      if (!overwriteIsStillValid() || _slotsRevision != startSlotsRevision) {
        return false;
      }

      final nextDailySlots = <String, List<TimeSlot>>{};
      for (final entry in snapshot.entriesByDate.entries) {
        final daySlots = _generateInitialSlots();
        _applyScheduleEntriesToSlots(daySlots, entry.value);
        nextDailySlots[entry.key] = daySlots;
      }

      // 持久化先于内存提交。SharedPreferences 的 set* 会返回 false，
      // 因此这里失败时尚未碰触 slots、撤销栈或待同步状态。
      final persisted = await _saveData(
        snapshot: _ScheduleSaveSnapshot(
          dailySlots: nextDailySlots,
          giteePendingDates: const {},
          googlePendingDates: const {},
          isStillValid: () =>
              overwriteIsStillValid() && _slotsRevision == startSlotsRevision,
        ),
      );
      // _saveData may have waited behind an earlier save.  The state that
      // made this snapshot valid must therefore be checked again after its
      // final asynchronous write and before changing provider memory.
      if (!persisted ||
          !overwriteIsStillValid() ||
          _slotsRevision != startSlotsRevision) {
        if (persisted) await _rollbackCommittedScheduleOverwrite();
        return false;
      }

      // The committed journal is still present.  Give the final identity /
      // revision guard one last observable phase before publishing memory and
      // allowing cleanup.  A test can inject a real identity or edit here;
      // production has no await between this guard and memory publication.
      try {
        _scheduleSnapshotJournalPhaseObserver?.call('before_remove');
      } catch (e) {
        debugPrint('覆盖快照提交阶段失败: $e');
        await _rollbackCommittedScheduleOverwrite();
        return false;
      }
      if (!overwriteIsStillValid() || _slotsRevision != startSlotsRevision) {
        await _rollbackCommittedScheduleOverwrite();
        return false;
      }

      // Cleanup is part of the overwrite transaction.  Set its lock before
      // publishing memory so synchronous listeners cannot start a mutation
      // between the commit and journal removal.
      _scheduleOverwriteCleanupInProgress = true;
      _dailySlots
        ..clear()
        ..addAll(nextDailySlots);
      _undoStacks.clear();
      _pendingSyncState.replace();
      _pendingScheduleGiteeDateKeys.clear();
      _scheduleGiteeDateRevisions.clear();
      _lastEditedDateKey = null;
      // 快照已一次性持久化；状态保持为干净，避免后续保存覆写它。
      _allSlotsDirty = false;
      _slotsDirty.clear();
      _slotsRevision++;
      _syncDirty = false;
      _targetStatsCache.invalidate();
      notifyListeners();
      // Removal is cleanup only. If the platform reports a failed/ambiguous
      // remove, _finalize... deliberately retains the committed journal; the
      // next startup will verify the new snapshot and retry cleanup instead of
      // rolling it back.
      final committedSlotsRevision = _slotsRevision;
      bool finalized;
      try {
        finalized = await _finalizeScheduleOverwriteJournal(
          isStillValid: () =>
              overwriteIsStillValid() &&
              _slotsRevision == committedSlotsRevision,
        );
      } finally {
        _scheduleOverwriteCleanupInProgress = false;
      }
      if (_isDisposed) return false;
      if (!finalized) {
        _lastScheduleOverwriteFailure = _scheduleOverwriteJournalCleanupPending
            ? '覆盖拉取已写入，但提交日志清理未完成，请稍后重试'
            : '覆盖拉取提交后状态发生变化，请重新确认';
        return false;
      }
      succeeded = true;
      _addScheduleSyncStatus('覆盖拉取完成');
      return true;
    } catch (e) {
      debugPrint('覆盖拉取失败: $e');
      _lastScheduleOverwriteFailure = '覆盖拉取未开始或失败，请稍后重试';
      return false;
    } finally {
      if (_scheduleOverwriteInProgress) {
        _scheduleOverwriteInProgress = false;
        _scheduleOverwriteCleanupInProgress = false;
        final shouldFlush = _deferredScheduleSaveRequested;
        _deferredScheduleSaveRequested = false;
        if (!_isDisposed && shouldFlush && !_initializationFailed) {
          unawaited(_saveData());
        }
      }
      if (!_isDisposed && !succeeded) {
        _lastScheduleOverwriteFailure ??= '覆盖拉取未开始或失败，请稍后重试';
        _addScheduleSyncStatus('覆盖拉取失败');
      }
      if (!_isDisposed) _addScheduleSyncStatus('');
    }
  }

  Future<bool> _rejectScheduleOverwrite(String message) async {
    if (_isDisposed) return false;
    _lastScheduleOverwriteFailure = message;
    _addScheduleSyncStatus(message);
    _addScheduleSyncStatus('');
    return false;
  }

  /// 拉取单日日程并与本地双向合并，返回是否成功。
  Future<bool> _pullScheduleDayFromGitee(
    String token,
    String dateKey, {
    required String userCode,
  }) async {
    if (!_canContinueScheduleSync(userCode)) return false;
    final result = await _scheduleSyncDependencies.pullDay(
      token: token,
      dateKey: dateKey,
      userCode: userCode,
    );
    if (!_canContinueScheduleSync(userCode)) return false;
    if (result.notFound || !result.success || result.content == null) {
      return false; // notFound/error 不中断整体，计入失败数
    }

    final remote = parseScheduleContent(result.content);
    final daySlots = _dailySlots.putIfAbsent(dateKey, _generateInitialSlots);
    final localEntries = _serializeRecordedSlots(daySlots);
    // 双向合并：union + 同槽 ts 大者胜，与推送 mergeScheduleSlots 完全对称
    final merged = mergeScheduleSlots(
      localEntries: localEntries,
      remoteEntries: remote.slots,
    );
    _applyScheduleEntriesToSlots(daySlots, merged);
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    return true;
  }

  // --- 分类（事件/子事件）跨端同步 ---

  /// 标记分类已修改：3 秒防抖后自动同步到 Gitee（远程视图下跳过）。
  void _markCategoriesGiteePending() {
    if (!_isScheduleReady ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewEnabled) {
      return;
    }
    // 捕获归属身份，避免随后切换身份导致同步到错误身份的文件
    _categoriesUserCode = _scheduleUser.code;
    _categoriesGiteeTimer?.cancel();
    _categoriesGiteeTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_syncCategoriesToGitee());
    });
  }

  /// 将本地分类同步到 Gitee：拉远端 → 合并 → 推送合并结果 → 写回本地。
  Future<void> _syncCategoriesToGitee() async {
    if (!_isScheduleReady || _scheduleOverwriteJournalCleanupPending) {
      return;
    }
    if (_remoteViewEnabled) return;
    if (!_hasSelectedScheduleUser) return;
    if (_categoriesGiteeSyncing) return;
    _categoriesGiteeSyncing = true;
    final userCode =
        _categoriesUserCode.isEmpty ? _scheduleUser.code : _categoriesUserCode;
    try {
      final token = await DiaryLocalStore.loadToken();
      if (!_isScheduleReady ||
          _scheduleOverwriteJournalCleanupPending ||
          !_hasSelectedScheduleUser ||
          _scheduleUser.code != userCode ||
          token == null ||
          token.isEmpty) {
        return;
      }

      final pullResult = await CategoryGiteeService.pullCategories(
          token: token, userCode: userCode);
      if (!_isScheduleReady ||
          _scheduleOverwriteJournalCleanupPending ||
          !_hasSelectedScheduleUser ||
          _scheduleUser.code != userCode) {
        return;
      }
      final localDoc = CategoryDocument(
        updatedAt: _categoriesDocUpdatedAt,
        categories: List.from(_categories),
        deletedCategories: Map.from(_deletedCategories),
      );
      final remoteDoc = pullResult.success && pullResult.content != null
          ? parseCategoryDocument(pullResult.content)
          : const CategoryDocument();
      final merged = mergeCategoryDocuments(local: localDoc, remote: remoteDoc);

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await CategoryGiteeService.pushCategories(
        token: token,
        userCode: userCode,
        content: encodeCategoryDocument(merged, nowMs: nowMs),
        commitMessage: 'categories($userCode): sync',
      );
      if (!_isScheduleReady ||
          _scheduleOverwriteJournalCleanupPending ||
          !_hasSelectedScheduleUser ||
          _scheduleUser.code != userCode) {
        return;
      }

      _applyMergedCategories(merged);
      _addScheduleSyncStatus('分类已同步');
      Future.delayed(const Duration(seconds: 3), () {
        _addScheduleSyncStatus('');
      });
    } catch (e) {
      debugPrint('分类同步失败: $e');
      _addScheduleSyncStatus('分类同步失败: $e');
    } finally {
      _categoriesGiteeSyncing = false;
    }
  }

  /// 从 Gitee 拉取当前身份的分类并合并到本地（只拉不推）。
  Future<void> _pullCategoriesFromGitee() async {
    if (!_isScheduleReady ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewEnabled ||
        _remoteViewTransitionInProgress) {
      return;
    }
    if (!_hasSelectedScheduleUser) return;
    if (_categoriesGiteeSyncing) return;
    _categoriesGiteeSyncing = true;
    final userCode = _scheduleUser.code;
    try {
      final token = await DiaryLocalStore.loadToken();
      if (!_isScheduleReady ||
          _scheduleOverwriteJournalCleanupPending ||
          _remoteViewEnabled ||
          _remoteViewTransitionInProgress ||
          !_hasSelectedScheduleUser ||
          _scheduleUser.code != userCode ||
          token == null ||
          token.isEmpty) {
        return;
      }
      final pullResult = await CategoryGiteeService.pullCategories(
          token: token, userCode: userCode);
      if (!_isScheduleReady ||
          _scheduleOverwriteJournalCleanupPending ||
          _remoteViewEnabled ||
          _remoteViewTransitionInProgress ||
          !_hasSelectedScheduleUser ||
          _scheduleUser.code != userCode ||
          !pullResult.success ||
          pullResult.content == null) {
        return;
      }
      final localDoc = CategoryDocument(
        updatedAt: _categoriesDocUpdatedAt,
        categories: List.from(_categories),
        deletedCategories: Map.from(_deletedCategories),
      );
      final remoteDoc = parseCategoryDocument(pullResult.content);
      final merged = mergeCategoryDocuments(local: localDoc, remote: remoteDoc);
      _applyMergedCategories(merged);
    } catch (e) {
      debugPrint('分类拉取失败: $e');
    } finally {
      _categoriesGiteeSyncing = false;
    }
  }

  /// 将合并结果写回本地分类状态并持久化。
  void _applyMergedCategories(CategoryDocument merged) {
    if (!_isScheduleReady ||
        _scheduleOverwriteCleanupInProgress ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      return;
    }
    _categories = merged.categories;
    _deletedCategories
      ..clear()
      ..addAll(merged.deletedCategories);
    _categoriesDocUpdatedAt = merged.updatedAt;
    _markCategoriesChanged();
    _saveData();
    notifyListeners();
  }

  /// 从 Gitee 拉取指定用户日程并合并到指定日期。
  /// [date] 为 null 时拉取当前选中日期。
  Future<bool> pullScheduleFromGitee({
    String? userCode,
    DateTime? date,
    int? requestRevision,
    bool allowRemoteViewTransition = false,
  }) async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _isDisposed ||
        _scheduleIdentityMutationInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        ((_remoteViewTransitionInProgress || _remoteViewEnabled) &&
            !allowRemoteViewTransition)) {
      return false;
    }
    if (_scheduleOverwriteInProgress) return false;
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return false;
    }
    final dateKey = _getDateKey(date ?? _currentDate);
    final code = userCode ?? _scheduleUser.code;
    final selectedUserCode = _scheduleUser.code;
    _scheduleMergePullsInProgress++;
    try {
      final token = await _scheduleSyncDependencies.loadToken();
      if (!_canContinueScheduleSync(
            selectedUserCode,
            allowRemoteViewTransition: allowRemoteViewTransition,
          ) ||
          _scheduleOverwriteInProgress ||
          token == null ||
          token.isEmpty) {
        _addScheduleSyncStatus('未配置同步 Token');
        return false;
      }
      _addScheduleSyncStatus('拉取中...');
      final result = await _scheduleSyncDependencies.pullDay(
        token: token,
        dateKey: dateKey,
        userCode: code,
      );
      if (!_canContinueScheduleSync(
            selectedUserCode,
            allowRemoteViewTransition: allowRemoteViewTransition,
          ) ||
          _scheduleOverwriteInProgress) {
        return false;
      }
      if (result.notFound) {
        _addScheduleSyncStatus('远端无数据');
        Future.delayed(const Duration(seconds: 3), () {
          _addScheduleSyncStatus('');
        });
        return false;
      }
      if (!result.success || result.content == null) {
        _addScheduleSyncStatus(result.error ?? '拉取失败');
        return false;
      }
      if (requestRevision != null && requestRevision != _schedulePullRevision) {
        return false;
      }

      if (_initializationFailed || _scheduleOverwriteJournalCleanupPending) {
        return false;
      }
      final remote = parseScheduleContent(result.content);
      final daySlots = _dailySlots.putIfAbsent(dateKey, _generateInitialSlots);
      final merged = mergeScheduleSlots(
        localEntries: _serializeRecordedSlots(daySlots),
        remoteEntries: remote.slots,
      );
      _applyScheduleEntriesToSlots(daySlots, merged);
      _markAllSlotsDirty();
      if (!_remoteViewEnabled) {
        final saved = await _saveData();
        if (!_canContinueScheduleSync(
              selectedUserCode,
              allowRemoteViewTransition: allowRemoteViewTransition,
            ) ||
            !saved) {
          return false;
        }
      }
      if (!_canContinueScheduleSync(
        selectedUserCode,
        allowRemoteViewTransition: allowRemoteViewTransition,
      )) {
        return false;
      }
      notifyListeners();
      _addScheduleSyncStatus('已同步');
      Future.delayed(const Duration(seconds: 3), () {
        _addScheduleSyncStatus('');
      });
      return true;
    } catch (e) {
      _addScheduleSyncStatus('拉取失败: $e');
      return false;
    } finally {
      _scheduleMergePullsInProgress--;
    }
  }

  /// 切换查看对方日程。打开时显示纯远端数据；关闭时恢复本地数据。
  /// Windows 三列视图下覆盖选中日及前后各一天，安卓仅覆盖选中日。
  Future<void> toggleRemoteScheduleView() async {
    if (!_canStartRemoteViewTransition()) {
      return;
    }
    final selectedUserCode = _scheduleUser.code;
    final transitionEpoch = ++_remoteViewTransitionEpoch;
    _remoteViewTransitionInProgress = true;
    bool transitionIsStillValid() =>
        !_isDisposed &&
        _remoteViewTransitionInProgress &&
        _remoteViewTransitionEpoch == transitionEpoch &&
        _hasSelectedScheduleUser &&
        _scheduleUser.code == selectedUserCode &&
        !_scheduleOverwriteInProgress &&
        !_scheduleOverwriteCleanupInProgress &&
        !_scheduleOverwriteJournalCleanupPending;

    try {
      final requestRevision = ++_schedulePullRevision;
      if (_remoteViewEnabled) {
        // 关闭：按备份过的日期逐一恢复本地数据
        final backupKeys = _remoteViewBackup.keys.toList();
        final remoteSlotsBeforeRestore = <String, List<TimeSlot>>{};
        final remoteSlotKeys = <String>{};
        for (final dk in backupKeys) {
          final existing = _dailySlots[dk];
          if (existing == null) continue;
          remoteSlotKeys.add(dk);
          remoteSlotsBeforeRestore[dk] = _cloneSlots(existing);
        }
        for (final dk in backupKeys) {
          final slots = _dailySlots[dk] ?? _generateInitialSlots();
          final backup = parseScheduleContent(_remoteViewBackup[dk]);
          _clearDaySlots(slots, clearModifiedAt: true);
          for (final map in backup.slots) {
            final idx = _parseInt(map['i']);
            if (idx == null) continue;
            if (idx >= 0 && idx < slots.length) {
              if (map['del'] == true) {
                // 删除墓碑：恢复为删除状态，避免被当成"空 label 的已记录槽"
                slots[idx].isFromCalendar = map['fc'] == true;
                final delTs = _parseInt(map['ts']);
                if (delTs != null && delTs > 0) {
                  slots[idx].deletedAt =
                      DateTime.fromMillisecondsSinceEpoch(delTs);
                }
                continue;
              }
              slots[idx].recorded = true;
              slots[idx].label = map['l'] as String?;
              slots[idx].categoryId = map['cid'] as String?;
              if (map['c'] != null) {
                final colorVal = _parseInt(map['c']);
                if (colorVal != null) slots[idx].color = Color(colorVal);
              }
              if (map['fc'] == true) slots[idx].isFromCalendar = true;
              if (map['eid'] != null) {
                slots[idx].calendarEventId = map['eid'] as String?;
              }
              final ts = _parseInt(map['ts']);
              if (ts != null && ts > 0) {
                slots[idx].modifiedAt = DateTime.fromMillisecondsSinceEpoch(ts);
              }
            }
          }
        }
        if (backupKeys.isNotEmpty) {
          _markAllSlotsDirty();
          final saved = await _saveDataForRemoteViewTransition(transitionEpoch);
          if (!transitionIsStillValid() || !saved) {
            _restoreRemoteViewSlots(
              backupKeys,
              remoteSlotsBeforeRestore,
              remoteSlotKeys,
            );
            if (!_isDisposed) notifyListeners();
            return;
          }
        }
        if (!transitionIsStillValid()) return;
        _remoteViewBackup.clear();
        _remoteViewEnabled = false;
      } else {
        // 打开：备份本地，清空日期，拉取纯远端数据
        // 注意顺序很重要：先取消待处理同步 → 保存当前数据 → 再切换视图

        // 1) 取消待处理的自动同步定时器，防止 3 秒后将对方数据推送到当前用户文件
        _scheduleGiteeTimer?.cancel();
        _scheduleGiteeTimer = null;
        _debounceTimer?.cancel();
        _debounceTimer = null;

        // 2) 先持久化当前用户的最新编辑，确保不丢失
        final saved = await _saveDataForRemoteViewTransition(transitionEpoch);
        if (!transitionIsStillValid() ||
            !saved ||
            _initializationFailed ||
            _scheduleOverwriteJournalCleanupPending) {
          return;
        }

        // 3) 备份并清空（Windows 三天 / 安卓一天）
        final dates = _getRemoteViewDates();
        for (final d in dates) {
          _backupAndClearDay(_getDateKey(d));
        }
        _markAllSlotsDirty();
        if (!transitionIsStillValid()) return;

        // 5) 提前标记远程视图状态，这样 pullScheduleFromGitee 内部的
        //    `if (!_remoteViewEnabled) _saveData()` 不会错误地保存到本地缓存
        _remoteViewEnabled = true;

        // 6) 拉取对方的文件（独立文件，无需过滤）；Windows 逐日拉取三天
        final otherCode = _scheduleUser.code == 'g' ? 'j' : 'g';
        for (final d in dates) {
          if (!transitionIsStillValid() ||
              _initializationFailed ||
              _scheduleOverwriteJournalCleanupPending) {
            return;
          }
          await pullScheduleFromGitee(
            userCode: otherCode,
            date: d,
            requestRevision: requestRevision,
            allowRemoteViewTransition: true,
          );
          if (!transitionIsStillValid() ||
              _initializationFailed ||
              _scheduleOverwriteJournalCleanupPending) {
            return;
          }
        }
        // 拉取后不保存到本地持久化——由提前设置的 _remoteViewEnabled 保证
      }
      if (transitionIsStillValid()) notifyListeners();
    } finally {
      if (_remoteViewTransitionEpoch == transitionEpoch) {
        _remoteViewTransitionInProgress = false;
      }
    }
  }

  bool _canStartRemoteViewTransition() {
    if (!_isScheduleIdentityReady ||
        _remoteViewTransitionInProgress ||
        _scheduleOverwriteInProgress ||
        _scheduleOverwriteCleanupInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        _scheduleIdentityMutationInProgress) {
      return false;
    }
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return false;
    }
    if (_hasScheduleSyncInFlight) {
      _addScheduleSyncStatus('已有日程同步任务，远程视图切换已忽略');
      return false;
    }
    return true;
  }

  List<TimeSlot> _cloneSlots(List<TimeSlot> source) {
    return source
        .map(
          (slot) => TimeSlot(
            hour: slot.hour,
            minute10: slot.minute10,
            recorded: slot.recorded,
            label: slot.label,
            categoryId: slot.categoryId,
            color: slot.color,
            isFromCalendar: slot.isFromCalendar,
            calendarEventId: slot.calendarEventId,
            modifiedAt: slot.modifiedAt,
            deletedAt: slot.deletedAt,
          ),
        )
        .toList();
  }

  void _restoreRemoteViewSlots(
    List<String> backupKeys,
    Map<String, List<TimeSlot>> snapshots,
    Set<String> existingKeys,
  ) {
    for (final dk in backupKeys) {
      final snapshot = snapshots[dk];
      if (snapshot != null) {
        _dailySlots[dk] = _cloneSlots(snapshot);
      } else if (!existingKeys.contains(dk)) {
        _dailySlots.remove(dk);
      }
    }
    // The local restore has not been persisted. Keep the next close attempt
    // responsible for writing it, while the remote view remains read-only.
    _allSlotsDirty = true;
  }

  /// 远程视图覆盖的日期：Windows 三列（选中日 ±1 天），安卓仅选中日。
  List<DateTime> _getRemoteViewDates() {
    return scheduleDatesForView(_currentDate, desktop: isDesktopPlatform);
  }

  /// 清空一天的槽位数据（远程视图备份/恢复用）
  void _clearDaySlots(List<TimeSlot> slots, {bool clearModifiedAt = false}) {
    for (final s in slots) {
      s.recorded = false;
      s.label = null;
      s.categoryId = null;
      s.color = null;
      s.isFromCalendar = false;
      s.calendarEventId = null;
      s.deletedAt = null;
      if (clearModifiedAt) s.modifiedAt = null;
    }
  }

  /// 本地与云端日历不一致时标记（与是否已登录无关）
  void _markPendingSync([String? dateKey]) {
    if (!_isScheduleReady ||
        _scheduleOverwriteCleanupInProgress ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      return;
    }
    final key = dateKey ?? _getDateKey(_currentDate);
    _pendingSyncState.markGitee(key);
    if (_supportsGoogleCalendarSync) {
      _pendingSyncState.markGoogle(key);
    }
    _syncDirty = true;
    _markScheduleGiteePending(key);
  }

  void _clearPendingGiteeForDate([String? dateKey]) {
    if (!_isScheduleReady ||
        _scheduleOverwriteCleanupInProgress ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      return;
    }
    final key = dateKey ?? _getDateKey(_currentDate);
    if (_pendingSyncState.giteeDates.contains(key)) {
      _pendingSyncState.clearGitee(key);
      _syncDirty = true;
      notifyListeners();
      _saveData();
    }
  }

  void _clearPendingGoogleForDate([String? dateKey]) {
    if (!_isScheduleReady ||
        _scheduleOverwriteCleanupInProgress ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      return;
    }
    final key = dateKey ?? _getDateKey(_currentDate);
    if (_pendingSyncState.googleDates.contains(key)) {
      _pendingSyncState.clearGoogle(key);
      _syncDirty = true;
      notifyListeners();
      _saveData();
    }
  }

  /// 应用切到后台：取消防抖计时、立即把本地数据与待同步标记写入磁盘
  Future<void> onAppBackgrounded() async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _scheduleGiteeTimer?.cancel();
    _scheduleGiteeTimer = null;
    await _flushPendingScheduleGiteeSync();
    if (_initializationFailed || _scheduleOverwriteJournalCleanupPending) {
      return;
    }
    await _saveData();
  }

  /// 统一同步：始终同步到 Gitee，若开启 Google 日历同步则同时同步 Google。
  Future<void> syncAll() async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _isDisposed ||
        _scheduleIdentityMutationInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      return;
    }
    if (isDesktopPlatform) {
      _scheduleGiteeTimer?.cancel();
      _scheduleGiteeTimer = null;
      await syncAllSchedulesToGitee();
      return;
    }
    // 保持当天优先，随后处理其他待同步日期。
    _scheduleGiteeTimer?.cancel();
    _scheduleGiteeTimer = null;
    final currentKey = _getDateKey(_currentDate);
    final giteeDates = PendingSyncState.orderDates(
      {...pendingGiteeSyncDates, currentKey},
      priorityDate: currentKey,
    );
    for (final dateKey in giteeDates) {
      if (_initializationFailed ||
          _scheduleOverwriteJournalCleanupPending ||
          _remoteViewTransitionInProgress ||
          _remoteViewEnabled) {
        return;
      }
      await syncScheduleToGitee(dateKey: dateKey);
    }

    // 若开启了 Google 日历同步则同步所有 Google 待同步日期。
    if (_googleCalendarSyncEnabled) {
      await synchronizeAllPendingCalendars();
    }
  }

  // 合并后的同步方法
  // delay: true 表示自动同步（带防抖），false 表示手动同步（立即执行）
  Future<void> synchronizeCalendar({bool delay = false}) async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _scheduleIdentityMutationInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled ||
        !_supportsGoogleCalendarSync ||
        !_googleCalendarSyncEnabled) {
      if (!delay) {
        _addSyncStatus('Google 日历同步已关闭');
      }
      return;
    }
    if (_scheduleOverwriteInProgress) return;
    final syncGeneration = _googleSyncGeneration;
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    Future<void> executeSync() async {
      if (_isDisposed ||
          _initializationFailed ||
          _scheduleIdentityMutationInProgress ||
          _scheduleOverwriteJournalCleanupPending ||
          _remoteViewTransitionInProgress ||
          _remoteViewEnabled ||
          syncGeneration != _googleSyncGeneration ||
          _isSyncing ||
          _scheduleOverwriteInProgress) {
        return;
      }

      if (!_isGoogleCalendarSignedIn) {
        if (!delay) {
          final msg = GoogleCalendarService.needsCalendarReconnect
              ? '日历未连接，请在设置中重新连接'
              : '未登录 Google 账号，无法同步';
          _addSyncStatus(msg);
        }
        return;
      }

      _isSyncing = true;
      try {
        _addSyncStatus("开始同步");
        if (delay) await Future.delayed(const Duration(milliseconds: 500));
        if (_isDisposed ||
            _initializationFailed ||
            _scheduleIdentityMutationInProgress ||
            _scheduleOverwriteJournalCleanupPending ||
            _remoteViewTransitionInProgress ||
            _remoteViewEnabled ||
            syncGeneration != _googleSyncGeneration ||
            _scheduleOverwriteInProgress) {
          return;
        }

        if (!_syncStatusController.isClosed) {
          _addSyncStatus("SYNCING");
        }

        bool pullOk = await pullGoogleCalendarForDate(
          _currentDate,
          notify: false,
          syncGeneration: syncGeneration,
        );
        // The pull itself is asynchronous.  An overwrite can begin after the
        // debounce check above, so guard immediately before the upload API.
        if (_isDisposed ||
            _initializationFailed ||
            _scheduleIdentityMutationInProgress ||
            _scheduleOverwriteJournalCleanupPending ||
            _remoteViewTransitionInProgress ||
            _remoteViewEnabled ||
            syncGeneration != _googleSyncGeneration ||
            _scheduleOverwriteInProgress) {
          return;
        }
        final pushGoogleDay = _scheduleSyncDependencies.pushGoogleDay ??
            GoogleCalendarService.syncSlotsToGoogle;
        final success = await pushGoogleDay(slots, _currentDate);

        if (_isDisposed ||
            _initializationFailed ||
            _scheduleOverwriteJournalCleanupPending ||
            _remoteViewTransitionInProgress ||
            _remoteViewEnabled ||
            syncGeneration != _googleSyncGeneration ||
            _scheduleOverwriteInProgress) {
          return;
        }

        if (success) {
          _clearPendingGoogleForDate();
          if (!delay) {
            if (!pullOk) {
              _addSyncStatus("同步成功（日历拉取失败）");
            } else {
              _addSyncStatus("同步成功");
            }
          }
        } else if (!delay) {
          if (!pullOk) {
            _addSyncStatus("从 Google 日历拉取失败");
          } else {
            _addSyncStatus("同步失败，请稍后重试");
          }
        }

        // 延迟重置状态
        Future.delayed(const Duration(seconds: 3), () {
          if (!_syncStatusController.isClosed) {
            _addSyncStatus("IDLE");
          }
        });
      } finally {
        _isSyncing = false;
      }
    }

    if (delay) {
      _debounceTimer = Timer(_googleCalendarDebounce, executeSync);
    } else {
      await executeSync();
    }
  }

  /// 手动同步所有待同步日期（用于个人中心“待同步”按钮）
  Future<void> synchronizeAllPendingCalendars() async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _isDisposed ||
        _scheduleIdentityMutationInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled ||
        !_googleCalendarSyncEnabled) {
      _addSyncStatus('Google 日历同步已关闭');
      return;
    }
    if (_scheduleOverwriteInProgress) return;
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    // 可能与自动同步并发：等待当前同步完成，避免手动点击被无声忽略
    var waitedMs = 0;
    while (_isSyncing && waitedMs < 10000) {
      await Future.delayed(const Duration(milliseconds: 200));
      waitedMs += 200;
    }
    if (_isDisposed ||
        _initializationFailed ||
        _scheduleIdentityMutationInProgress ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled ||
        _isSyncing ||
        _scheduleOverwriteInProgress) {
      _addSyncStatus("同步进行中，请稍后重试");
      return;
    }

    if (!_isGoogleCalendarSignedIn) {
      _addSyncStatus("未登录 Google 账号，无法同步");
      return;
    }

    final pendingKeys = PendingSyncState.orderDates(
      {...pendingGoogleSyncDates, _getDateKey(_currentDate)},
      priorityDate: _getDateKey(_currentDate),
    );

    _isSyncing = true;
    try {
      _addSyncStatus("SYNCING");

      var allSuccess = true;
      for (final rawKey in pendingKeys) {
        if (_isDisposed ||
            _initializationFailed ||
            _scheduleIdentityMutationInProgress ||
            _scheduleOverwriteJournalCleanupPending ||
            _remoteViewTransitionInProgress ||
            _remoteViewEnabled ||
            _scheduleOverwriteInProgress) {
          allSuccess = false;
          break;
        }
        final dateKey = rawKey.trim();
        final parts = dateKey.split('-');
        if (parts.length != 3) continue;

        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);
        if (year == null || month == null || day == null) {
          // 异常 key 直接清掉，避免状态永远卡在“待同步”
          _pendingSyncState.clearGoogle(rawKey);
          _syncDirty = true;
          allSuccess = false;
          continue;
        }

        final date = DateTime(year, month, day);
        if (_isDisposed ||
            _initializationFailed ||
            _scheduleIdentityMutationInProgress ||
            _scheduleOverwriteJournalCleanupPending ||
            _scheduleOverwriteInProgress) {
          allSuccess = false;
          break;
        }
        final result = await synchronizePendingGoogleDay(
          dailySlots: _dailySlots,
          dateKey: dateKey,
          explicitlyPending: pendingGoogleSyncDates.contains(dateKey),
          createSlots: _generateInitialSlots,
          pull: () => pullGoogleCalendarForDate(date, notify: false),
          canContinue: () =>
              _isInitialLoadFinished &&
              !_isDisposed &&
              !_initializationFailed &&
              !_scheduleIdentityMutationInProgress &&
              !_scheduleOverwriteJournalCleanupPending &&
              !_remoteViewTransitionInProgress &&
              !_remoteViewEnabled &&
              !_scheduleOverwriteInProgress,
          push: (slotsForDay) {
            if (_isDisposed ||
                _initializationFailed ||
                _scheduleIdentityMutationInProgress ||
                _scheduleOverwriteJournalCleanupPending ||
                _remoteViewTransitionInProgress ||
                _remoteViewEnabled ||
                _scheduleOverwriteInProgress) {
              return Future.value(false);
            }
            final pushGoogleDay = _scheduleSyncDependencies.pushGoogleDay ??
                GoogleCalendarService.syncSlotsToGoogle;
            return pushGoogleDay(slotsForDay, date);
          },
        );

        if (_isDisposed ||
            _initializationFailed ||
            _scheduleIdentityMutationInProgress ||
            _scheduleOverwriteJournalCleanupPending ||
            _remoteViewTransitionInProgress ||
            _remoteViewEnabled ||
            _scheduleOverwriteInProgress) {
          allSuccess = false;
          break;
        }

        if (result.pushSucceeded == true) {
          _pendingSyncState.clearGoogle(dateKey);
          _syncDirty = true;
        } else if (result.pushSucceeded == false) {
          allSuccess = false;
        }

        if (!result.pullSucceeded) {
          allSuccess = false;
        }
      }

      if (_isDisposed ||
          _initializationFailed ||
          _scheduleIdentityMutationInProgress ||
          _scheduleOverwriteJournalCleanupPending ||
          _remoteViewTransitionInProgress ||
          _remoteViewEnabled) {
        return;
      }
      final saved = await _saveData();
      if (_isDisposed ||
          _initializationFailed ||
          _scheduleIdentityMutationInProgress ||
          _scheduleOverwriteJournalCleanupPending ||
          _remoteViewTransitionInProgress ||
          _remoteViewEnabled ||
          !saved) {
        return;
      }
      notifyListeners();
      if (pendingGoogleSyncDates.isEmpty && allSuccess) {
        _addSyncStatus("同步成功");
      } else {
        _addSyncStatus("部分同步失败（剩余${pendingGoogleSyncDates.length}天）");
      }
    } finally {
      _isSyncing = false;
      Future.delayed(const Duration(seconds: 3), () {
        if (!_syncStatusController.isClosed) {
          _addSyncStatus("IDLE");
        }
      });
    }
  }

  // 移除指定时间块的事件
  void removeEventFromSlot(int index, {DateTime? date}) {
    if (!_allowScheduleMutation() || _remoteViewEnabled) return;
    final targetDate = date ?? _currentDate;
    final dateKey = _getDateKey(targetDate);
    final daySlots = slotsForDate(targetDate);
    if (index >= 0 && index < daySlots.length) {
      if (daySlots[index].recorded) {
        final wasFromCalendar = daySlots[index].isFromCalendar;
        _saveSnapshot(dateKey);
        if (wasFromCalendar) {
          _dismissCalendarImportAt(index, date: targetDate);
        } else {
          _clearSlotAt(daySlots, index, markDeleted: true);
          _markSlotsDirty(dateKey);
          _targetStatsCache.invalidateDate(dateKey);
          // 编辑当前日期走完整同步链路；三列视图的其他日期也要同步到对应 Gitee 文件。
          if (date == null || dateKey == _getDateKey(_currentDate)) {
            _markPendingSync();
            _scheduleCalendarSync();
          } else {
            _markPendingSync(dateKey);
          }
          _saveData();
          notifyListeners();
          _addTargetStatsChanged(); // 通知目标统计变化
        }
      }
    }
  }

  void _clearSlotAt(List<TimeSlot> daySlots, int index,
      {bool markDeleted = false}) {
    final wasFromCalendar = daySlots[index].isFromCalendar;
    daySlots[index].recorded = false;
    daySlots[index].label = null;
    daySlots[index].categoryId = null;
    daySlots[index].color = null;
    // Google 导入的墓碑保留来源，合并时只能清理 Google 副本。
    daySlots[index].isFromCalendar = markDeleted && wasFromCalendar;
    daySlots[index].calendarEventId = null;
    if (markDeleted) {
      daySlots[index].deletedAt = DateTime.now();
    } else {
      daySlots[index].deletedAt = null;
    }
  }

  Future<void> _dismissCalendarImportAt(int index, {DateTime? date}) async {
    if (!_isScheduleReady || _scheduleOverwriteCleanupInProgress) return;
    final targetDate = date ?? _currentDate;
    final dateKey = _getDateKey(targetDate);
    final daySlots = slotsForDate(targetDate);

    final label = daySlots[index].label ?? '';
    int start = index;
    while (start > 0 &&
        daySlots[start - 1].isFromCalendar &&
        daySlots[start - 1].label == label) {
      start--;
    }
    int end = index + 1;
    while (end < daySlots.length &&
        daySlots[end].isFromCalendar &&
        daySlots[end].label == label) {
      end++;
    }

    final rangeStart = _slotIndexToDateTime(start, targetDate);
    final rangeEnd = _slotIndexToDateTime(end, targetDate);
    final eventId = daySlots[index].calendarEventId;
    for (int i = 0; i < daySlots.length; i++) {
      final sameEvent = eventId != null &&
          eventId.isNotEmpty &&
          daySlots[i].calendarEventId == eventId;
      final inRange = i >= start &&
          i < end &&
          daySlots[i].isFromCalendar &&
          daySlots[i].label == label;
      if (sameEvent || inRange) {
        _clearSlotAt(daySlots, i, markDeleted: true);
      }
    }

    _markSlotsDirty(dateKey); // 标记当前日期为脏
    _calendarDirty = true; // 忽略列表也变了
    _targetStatsCache.invalidateDate(dateKey); // 失效该日期的缓存
    if (!_isDisposed) {
      notifyListeners();
    }

    // Publish the tombstone immediately so callers see a synchronous local
    // deletion.  The network deletion and any ignore marker are persisted in
    // the continuation below.
    final initialSave = _saveData();
    var resolvedEventId = eventId;
    if (resolvedEventId == null || resolvedEventId.isEmpty) {
      resolvedEventId = await _resolveGoogleEventId(
        label,
        rangeStart,
        rangeEnd,
        targetDate,
      );
    }
    if (_isDisposed ||
        _initializationFailed ||
        _scheduleOverwriteJournalCleanupPending) {
      return;
    }

    var needsSecondSave = false;
    if (resolvedEventId != null && resolvedEventId.isNotEmpty) {
      final deleted = await GoogleCalendarService.deleteExternalEvent(
        resolvedEventId,
      );
      if (_isDisposed ||
          _initializationFailed ||
          _scheduleOverwriteJournalCleanupPending) {
        return;
      }
      if (!deleted) {
        _ignoredCalendarImports
            .putIfAbsent(dateKey, () => {})
            .add(resolvedEventId);
        needsSecondSave = true;
        if (!_syncStatusController.isClosed) {
          _addSyncStatus("删除 Google 日历事件失败");
        }
      }
    } else {
      _ignoredCalendarImports.putIfAbsent(dateKey, () => {}).add(
            _calendarBlockFingerprint(label, rangeStart, rangeEnd),
          );
      needsSecondSave = true;
    }

    final saved = await initialSave;
    if (!saved ||
        _isDisposed ||
        _initializationFailed ||
        _scheduleOverwriteJournalCleanupPending) {
      return;
    }
    if (needsSecondSave) {
      final ignoredSaved = await _saveData();
      if (!ignoredSaved || _isDisposed) return;
      notifyListeners();
    }
  }

  Future<String?> _resolveGoogleEventId(String title, DateTime rangeStart,
      DateTime rangeEnd, DateTime targetDate) async {
    if (!_isScheduleReady || _scheduleOverwriteCleanupInProgress) return null;
    final blocks = await GoogleCalendarService.fetchExternalEvents(targetDate);
    if (blocks == null ||
        _isDisposed ||
        _initializationFailed ||
        _scheduleOverwriteJournalCleanupPending) {
      return null;
    }

    for (final block in blocks) {
      if (block.title != title) continue;
      if (block.eventId == null || block.eventId!.isEmpty) continue;
      if (block.start.isAtSameMomentAs(rangeStart) &&
          block.end.isAtSameMomentAs(rangeEnd)) {
        return block.eventId;
      }
      if (!block.end.isAfter(rangeStart) || !block.start.isBefore(rangeEnd)) {
        continue;
      }
      return block.eventId;
    }
    return null;
  }

  String _calendarBlockFingerprint(String title, DateTime start, DateTime end) {
    return 'fp:$title|${start.millisecondsSinceEpoch}|${end.millisecondsSinceEpoch}';
  }

  bool _isCalendarBlockIgnored(String dateKey, CalendarBlock block) {
    final ignored = _ignoredCalendarImports[dateKey];
    if (ignored == null || ignored.isEmpty) return false;
    if (block.eventId != null &&
        block.eventId!.isNotEmpty &&
        ignored.contains(block.eventId)) {
      return true;
    }
    return ignored.contains(_calendarBlockFingerprint(
      block.title,
      block.start,
      block.end,
    ));
  }

  DateTime _slotIndexToDateTime(int index, [DateTime? date]) {
    final d = date ?? _currentDate;
    return DateTime(d.year, d.month, d.day, index ~/ 6, (index % 6) * 10);
  }

  /// 将 slot 索引转换为 HH:mm 格式时间字符串。
  String _slotIndexToTimeString(int index) {
    final h = index ~/ 6;
    final m = (index % 6) * 10;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// 将按索引排序的条目分组为连续时间段（同标签相邻 slot 合并为一个事件）。
  /// 返回 [{label, startIndex, endIndex}]，endIndex 为该段最后一个 slot 的 index + 1。
  List<({String label, int start, int end})> _groupConsecutiveSlots(
      List<Map<String, dynamic>> entries) {
    if (entries.isEmpty) return [];
    final sorted = List<Map<String, dynamic>>.from(entries)
      ..sort(
          (a, b) => (_parseInt(a['i']) ?? 0).compareTo(_parseInt(b['i']) ?? 0));
    final result = <({String label, int start, int end})>[];
    var start = _parseInt(sorted.first['i']) ?? 0;
    var prevLabel = sorted.first['l']?.toString() ?? '';
    var prevIndex = start;
    for (int i = 1; i < sorted.length; i++) {
      final curIndex = _parseInt(sorted[i]['i']) ?? 0;
      final curLabel = sorted[i]['l']?.toString() ?? '';
      if (curLabel != prevLabel || curIndex != prevIndex + 1) {
        result.add((label: prevLabel, start: start, end: prevIndex + 1));
        start = curIndex;
        prevLabel = curLabel;
      }
      prevIndex = curIndex;
    }
    result.add((label: prevLabel, start: start, end: prevIndex + 1));
    return result;
  }

  /// 生成日程差异描述的 commit message。
  /// 对比旧数据（Gitee 上的内容）与新数据，返回格式化的变更摘要。
  String _buildScheduleDiffMessage(
    String userLabel,
    String dateKey,
    String? oldContent,
    List<Map<String, dynamic>> newEntries,
  ) {
    // 解析旧数据（兼容新对象格式与旧裸数组格式）
    final Map<int, Map<String, dynamic>> oldByIndex = {};
    if (oldContent != null && oldContent.isNotEmpty) {
      final old = parseScheduleContent(oldContent);
      for (final map in old.slots) {
        final idx = _parseInt(map['i']);
        if (idx == null) continue;
        oldByIndex[idx] = map;
      }
    }

    // 按 index 索引新数据
    final Map<int, Map<String, dynamic>> newByIndex = {};
    for (final entry in newEntries) {
      final idx = _parseInt(entry['i']);
      if (idx == null) continue;
      newByIndex[idx] = entry;
    }

    // 对比分类
    final added = <({String label, int start, int end})>[];
    final deleted = <({String label, int start, int end})>[];
    final modified = <({String label, int start, int end, String oldLabel})>[];

    // 分别提取新增、删除、修改的条目
    final addedEntries = <Map<String, dynamic>>[];
    final deletedEntries = <Map<String, dynamic>>[];
    final modifiedEntries = <Map<String, dynamic>>[];
    final modifiedOldLabels = <int, String>{};

    for (final idx in newByIndex.keys) {
      final newEntry = newByIndex[idx]!;
      if (newEntry['del'] == true) {
        // 墓碑：旧数据有此槽则视为"删除"，旧数据无则忽略（纯清理）
        if (oldByIndex.containsKey(idx)) {
          deletedEntries.add(oldByIndex[idx]!);
        }
        continue;
      }
      if (!oldByIndex.containsKey(idx)) {
        addedEntries.add(newEntry);
      } else {
        final oldLabel = oldByIndex[idx]!['l']?.toString() ?? '';
        final newLabel = newEntry['l']?.toString() ?? '';
        if (oldLabel != newLabel) {
          modifiedEntries.add(newEntry);
          modifiedOldLabels[idx] = oldLabel;
        }
      }
    }
    for (final idx in oldByIndex.keys) {
      if (!newByIndex.containsKey(idx)) {
        deletedEntries.add(oldByIndex[idx]!);
      }
    }

    // 分组
    for (final group in _groupConsecutiveSlots(addedEntries)) {
      added.add(group);
    }
    for (final group in _groupConsecutiveSlots(deletedEntries)) {
      deleted.add(group);
    }
    // 修改的条目需要单独处理：提取时带上旧标签
    if (modifiedEntries.isNotEmpty) {
      final modifiedSorted = List<Map<String, dynamic>>.from(modifiedEntries)
        ..sort((a, b) =>
            (_parseInt(a['i']) ?? 0).compareTo(_parseInt(b['i']) ?? 0));
      var start = _parseInt(modifiedSorted.first['i']) ?? 0;
      var prevOldLabel = modifiedOldLabels[start] ?? '';
      var prevNewLabel = modifiedSorted.first['l']?.toString() ?? '';
      var prevIndex = start;
      for (int i = 1; i < modifiedSorted.length; i++) {
        final curIndex = _parseInt(modifiedSorted[i]['i']) ?? 0;
        final curNewLabel = modifiedSorted[i]['l']?.toString() ?? '';
        final curOldLabel = modifiedOldLabels[curIndex] ?? '';
        // 如果新旧标签对不一致，不能合并
        if (curNewLabel != prevNewLabel ||
            curOldLabel != prevOldLabel ||
            curIndex != prevIndex + 1) {
          modified.add((
            label: prevNewLabel,
            start: start,
            end: prevIndex + 1,
            oldLabel: prevOldLabel
          ));
          start = curIndex;
          prevNewLabel = curNewLabel;
          prevOldLabel = curOldLabel;
        }
        prevIndex = curIndex;
      }
      modified.add((
        label: prevNewLabel,
        start: start,
        end: prevIndex + 1,
        oldLabel: prevOldLabel
      ));
    }

    // 格式化事件描述
    String formatEvent(({String label, int start, int end}) ev) {
      final timeStr = ev.start == ev.end - 1
          ? _slotIndexToTimeString(ev.start)
          : '${_slotIndexToTimeString(ev.start)}-${_slotIndexToTimeString(ev.end)}';
      return '$timeStr ${ev.label}';
    }

    String formatModified(
        ({String label, int start, int end, String oldLabel}) ev) {
      final timeStr = ev.start == ev.end - 1
          ? _slotIndexToTimeString(ev.start)
          : '${_slotIndexToTimeString(ev.start)}-${_slotIndexToTimeString(ev.end)}';
      return '$timeStr ${ev.oldLabel} → ${ev.label}';
    }

    final parts = <String>[];
    const maxDisplay = 3;

    if (added.isNotEmpty) {
      final items = added.take(maxDisplay).map(formatEvent).join(', ');
      final suffix = added.length > maxDisplay ? ' 等${added.length}条' : '';
      parts.add('新增: $items$suffix');
    }
    if (deleted.isNotEmpty) {
      final items = deleted.take(maxDisplay).map(formatEvent).join(', ');
      final suffix = deleted.length > maxDisplay ? ' 等${deleted.length}条' : '';
      parts.add('删除: $items$suffix');
    }
    if (modified.isNotEmpty) {
      final items = modified.take(maxDisplay).map(formatModified).join(', ');
      final suffix =
          modified.length > maxDisplay ? ' 等${modified.length}条' : '';
      parts.add('修改: $items$suffix');
    }

    if (parts.isEmpty) {
      // 无变化：列出当前所有日程（墓碑不参与展示）
      final allEvents = _groupConsecutiveSlots(
          newEntries.where((e) => e['del'] != true).toList());
      final lines = allEvents.take(5).map(formatEvent).toList();
      final suffix = allEvents.length > 5 ? ' 等${allEvents.length}条' : '';
      return '日程($userLabel): $dateKey\n${lines.join('\n')}$suffix';
    }

    return '日程($userLabel): $dateKey\n${parts.join('\n')}';
  }

  // --- Google 日历下拉 ---

  Future<void> pullGoogleCalendarForCurrentDate() async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled ||
        !_supportsGoogleCalendarSync ||
        !_googleCalendarSyncEnabled) {
      return;
    }
    await pullGoogleCalendarForDate(_currentDate);
  }

  /// 从 Google 拉取外部会议并合并到指定日期；未登录 Google 时返回 false
  Future<bool> pullGoogleCalendarForDate(DateTime date,
      {bool notify = true, int? syncGeneration}) async {
    if (!_isInitialLoadFinished ||
        !_scheduleUserLoadFinished ||
        _initializationFailed ||
        _isDisposed ||
        _scheduleOverwriteJournalCleanupPending ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled ||
        !_supportsGoogleCalendarSync ||
        !_googleCalendarSyncEnabled) {
      return false;
    }
    if (syncGeneration != null && syncGeneration != _googleSyncGeneration) {
      return false;
    }
    if (!_isGoogleCalendarSignedIn) return false;
    if (_scheduleIdentityMutationInProgress ||
        _scheduleOverwriteInProgress ||
        _remoteViewTransitionInProgress ||
        _remoteViewEnabled) {
      return false;
    }

    _googleCalendarPullsInProgress++;
    try {
      final pullGoogleDay = _scheduleSyncDependencies.pullGoogleDay ??
          GoogleCalendarService.fetchExternalEvents;
      final blocks = await pullGoogleDay(date);
      if (blocks == null ||
          _isDisposed ||
          _initializationFailed ||
          _scheduleIdentityMutationInProgress ||
          _scheduleOverwriteJournalCleanupPending ||
          _remoteViewTransitionInProgress ||
          _remoteViewEnabled ||
          (syncGeneration != null && syncGeneration != _googleSyncGeneration) ||
          _scheduleOverwriteInProgress) {
        return false;
      }
      final dateKey = _getDateKey(date);
      _mergeCalendarBlocks(dateKey, blocks, date);
      _markSlotsDirty(dateKey);
      _targetStatsCache.invalidateDate(dateKey); // 失效该日期的缓存
      final saved = await _saveData();
      if (_isDisposed ||
          _initializationFailed ||
          _scheduleIdentityMutationInProgress ||
          _scheduleOverwriteJournalCleanupPending ||
          _remoteViewTransitionInProgress ||
          _remoteViewEnabled ||
          (syncGeneration != null && syncGeneration != _googleSyncGeneration) ||
          _scheduleOverwriteInProgress ||
          !saved) {
        return false;
      }
      if (notify) notifyListeners();
      return true;
    } finally {
      _googleCalendarPullsInProgress--;
    }
  }

  void _mergeCalendarBlocks(
      String dateKey, List<CalendarBlock> blocks, DateTime day) {
    final daySlots =
        _dailySlots.putIfAbsent(dateKey, () => _generateInitialSlots());

    for (int i = 0; i < daySlots.length; i++) {
      if (shouldClearCalendarSlotForRefresh(daySlots[i])) {
        _clearSlotAt(daySlots, i);
      }
    }

    for (final block in blocks) {
      if (_isCalendarBlockIgnored(dateKey, block)) continue;

      final indices = _timeRangeToSlotIndices(block.start, block.end, day);
      for (final index in indices) {
        if (index < 0 || index >= daySlots.length) continue;
        if (daySlots[index].recorded) continue;
        daySlots[index].recorded = true;
        daySlots[index].label = block.title;
        daySlots[index].color = calendarImportColor;
        daySlots[index].isFromCalendar = true;
        daySlots[index].calendarEventId = block.eventId;
        daySlots[index].deletedAt = null; // 日历块重新拉入，清除可能残留的墓碑
      }
    }
  }

  List<int> _timeRangeToSlotIndices(
      DateTime start, DateTime end, DateTime day) {
    return calendarTimeRangeToSlotIndices(start, end, day);
  }

  // --- 日程模板 ---

  List<Map<String, dynamic>> _serializeRecordedSlots(List<TimeSlot> slotList,
      {bool excludeCalendar = false}) {
    final recorded = <Map<String, dynamic>>[];
    for (int i = 0; i < slotList.length; i++) {
      final slot = slotList[i];
      if (slot.deletedAt != null) {
        // 删除墓碑：本地已删、远端仍可能有旧数据的槽位，需随同步传播删除
        final entry = <String, dynamic>{
          'i': i,
          'del': true,
          'ts': slot.deletedAt!.millisecondsSinceEpoch,
        };
        if (slot.isFromCalendar) entry['fc'] = true;
        recorded.add(entry);
        continue;
      }
      if (!slot.recorded) continue;
      if (excludeCalendar && slot.isFromCalendar) continue;
      final entry = <String, dynamic>{
        'i': i,
        'l': slot.label,
        'c': slot.color?.toARGB32(),
      };
      if (slot.modifiedAt != null) {
        entry['ts'] = slot.modifiedAt!.millisecondsSinceEpoch;
      }
      if (slot.categoryId != null && slot.categoryId!.isNotEmpty) {
        entry['cid'] = slot.categoryId;
      }
      if (slot.isFromCalendar) {
        entry['fc'] = true;
      }
      if (slot.calendarEventId != null) {
        entry['eid'] = slot.calendarEventId;
      }
      recorded.add(entry);
    }
    return recorded;
  }

  List<TemplateSlot> _recordedSlotsFromDay(List<TimeSlot> slotList,
      {bool excludeCalendar = false}) {
    return _serializeRecordedSlots(slotList, excludeCalendar: excludeCalendar)
        .map((m) => TemplateSlot(
              index: _parseInt(m['i']) ?? 0,
              label: m['l'] as String? ?? '',
              categoryId: m['cid'] as String?,
              colorArgb: _parseInt(m['c']),
            ))
        .where((s) => s.label.isNotEmpty)
        .toList();
  }

  /// 从当日记录保存模板；无记录时返回 false
  bool saveTemplateFromCurrentDay(String name) {
    if (!_allowScheduleMutation()) return false;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;

    final entries = _recordedSlotsFromDay(slots);
    if (entries.isEmpty) return false;

    _templates.add(ScheduleTemplate(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: trimmed,
      slots: entries,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    _markTemplatesChanged(); // 标记模板为脏
    _saveData();
    notifyListeners();
    return true;
  }

  /// 模板格与当日已记录格在相同索引上内容不一致时视为冲突
  bool hasTemplateConflictWithCurrentDay(String id) {
    final index = _templates.indexWhere((t) => t.id == id);
    if (index == -1) return false;
    final template = _templates[index];
    final daySlots = slots;

    for (final entry in template.slots) {
      if (entry.index < 0 || entry.index >= daySlots.length) continue;
      final slot = daySlots[entry.index];
      if (!slot.recorded) continue;
      if (!_slotMatchesTemplateEntry(slot, entry)) return true;
    }
    return false;
  }

  bool _slotMatchesTemplateEntry(TimeSlot slot, TemplateSlot entry) {
    if (!slot.recorded || slot.label != entry.label) return false;
    if (entry.categoryId != null &&
        entry.categoryId!.isNotEmpty &&
        slot.categoryId != entry.categoryId) {
      return false;
    }
    if (entry.colorArgb == null) return true;
    return slot.color?.toARGB32() == entry.colorArgb;
  }

  void applyTemplate(String id, ApplyTemplateMode mode) {
    final index = _templates.indexWhere((t) => t.id == id);
    if (index == -1) return;
    final template = _templates[index];
    if (template.slots.isEmpty) return;

    _applySlotEntries(template.slots, mode);
  }

  DateTime get _yesterdayDate => _currentDate.subtract(const Duration(days: 1));

  List<TimeSlot>? get _yesterdaySlots {
    final key = _getDateKey(_yesterdayDate);
    return _dailySlots[key];
  }

  /// 昨天是否有可复制的用户记录（不含日历导入）
  bool get hasYesterdayToCopy {
    final daySlots = _yesterdaySlots;
    if (daySlots == null) return false;
    return daySlots.any((s) => s.recorded && !s.isFromCalendar);
  }

  List<TemplateSlot> _yesterdayCopyEntries() {
    final daySlots = _yesterdaySlots;
    if (daySlots == null) return [];
    return _recordedSlotsFromDay(daySlots, excludeCalendar: true);
  }

  /// 复制昨天安排是否与当天已有记录冲突
  bool hasCopyYesterdayConflict() {
    final entries = _yesterdayCopyEntries();
    if (entries.isEmpty) return false;
    final daySlots = slots;
    for (final entry in entries) {
      if (entry.index < 0 || entry.index >= daySlots.length) continue;
      final slot = daySlots[entry.index];
      if (!slot.recorded) continue;
      if (!_slotMatchesTemplateEntry(slot, entry)) return true;
    }
    return false;
  }

  /// 将昨天安排复制到当前日；无可复制内容时返回 false
  bool copyFromYesterday(
      {ApplyTemplateMode mode = ApplyTemplateMode.fillEmptyOnly}) {
    final entries = _yesterdayCopyEntries();
    if (entries.isEmpty) return false;
    _applySlotEntries(entries, mode);
    return true;
  }

  void _applySlotEntries(List<TemplateSlot> entries, ApplyTemplateMode mode) {
    if (!_allowScheduleMutation() || _remoteViewEnabled) return;
    _saveSnapshot();

    final dateKey = _getDateKey(_currentDate);
    if (mode == ApplyTemplateMode.replaceAll) {
      _dailySlots[dateKey] = _generateInitialSlots();
      // 恢复日历导入事件（replaceAll 清空了全部 slot，需要重新拉取日历数据）
      if (_googleCalendarSyncEnabled) {
        unawaited(pullGoogleCalendarForCurrentDate());
      }
    }

    final daySlots = slots;
    for (final entry in entries) {
      if (entry.index < 0 || entry.index >= daySlots.length) continue;
      if (mode == ApplyTemplateMode.fillEmptyOnly &&
          daySlots[entry.index].recorded) {
        continue;
      }
      daySlots[entry.index].recorded = true;
      daySlots[entry.index].label = entry.label;
      daySlots[entry.index].categoryId =
          entry.categoryId ?? resolveCategoryIdForLabel(entry.label);
      daySlots[entry.index].isFromCalendar = false;
      daySlots[entry.index].calendarEventId = null;
      if (entry.colorArgb != null) {
        daySlots[entry.index].color = Color(entry.colorArgb!);
      }
    }

    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    _markPendingSync();
    _saveData();
    notifyListeners();
    _addTargetStatsChanged(); // 通知目标统计变化
    _scheduleCalendarSync();
  }

  void renameTemplate(String id, String newName) {
    if (!_allowScheduleMutation()) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final index = _templates.indexWhere((t) => t.id == id);
    if (index == -1) return;
    _templates[index] = _templates[index].copyWith(name: trimmed);
    _markTemplatesChanged(); // 标记模板为脏
    _saveData();
    notifyListeners();
  }

  void deleteTemplate(String id) {
    if (!_allowScheduleMutation()) return;
    _templates.removeWhere((t) => t.id == id);
    _markTemplatesChanged(); // 标记模板为脏
    _saveData();
    notifyListeners();
  }

  // --- 分类管理方法 (从 HomeScreen 移入) ---

  void addCategory(Category category) {
    if (!_allowScheduleMutation()) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _categories.add(category.updatedAt <= 0
        ? category.copyWith(updatedAt: nowMs)
        : category);
    _markCategoriesChanged();
    _markCategoriesGiteePending();
    _invalidateLabelCategoryIdCache(); // 清除缓存
    _saveData();
    notifyListeners();
  }

  void updateCategory(int index, Category newCategory) {
    if (!_allowScheduleMutation()) return;
    if (index < 0 || index >= _categories.length) return;

    final oldCategory = _categories[index];
    final updated = newCategory.id.isEmpty
        ? newCategory.copyWith(id: oldCategory.id)
        : newCategory;
    final categoryId = oldCategory.id;

    if (oldCategory.name != updated.name) {
      _propagateLabelRename(categoryId, oldCategory.name, updated.name);
    }

    final oldSubs = oldCategory.subCategories;
    final newSubs = updated.subCategories;
    if (oldSubs.length == newSubs.length) {
      for (int i = 0; i < oldSubs.length; i++) {
        if (oldSubs[i] != newSubs[i]) {
          _propagateLabelRename(categoryId, oldSubs[i], newSubs[i]);
        }
      }
    }

    _categories[index] =
        updated.copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch);
    _markCategoriesChanged();
    _markCategoriesGiteePending();
    _invalidateLabelCategoryIdCache(); // 清除缓存
    _saveData();
    notifyListeners();
  }

  void hideSubCategory(int catIndex, String subCategory) {
    if (!_allowScheduleMutation()) return;
    if (catIndex < 0 || catIndex >= _categories.length) return;
    final cat = _categories[catIndex];
    final newSubs = List<String>.from(cat.subCategories)..remove(subCategory);
    final newHidden = List<String>.from(cat.hiddenSubCategories)
      ..add(subCategory);
    _categories[catIndex] = cat.copyWith(
      subCategories: newSubs,
      hiddenSubCategories: newHidden,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _markCategoriesChanged(); // 标记分类为脏
    _markCategoriesGiteePending();
    _saveData();
    notifyListeners();
  }

  void restoreSubCategory(int catIndex, String subCategory) {
    if (!_allowScheduleMutation()) return;
    if (catIndex < 0 || catIndex >= _categories.length) return;
    final cat = _categories[catIndex];
    final newHidden = List<String>.from(cat.hiddenSubCategories)
      ..remove(subCategory);
    final newSubs = List<String>.from(cat.subCategories)..add(subCategory);
    _categories[catIndex] = cat.copyWith(
      subCategories: newSubs,
      hiddenSubCategories: newHidden,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _markCategoriesChanged(); // 标记分类为脏
    _markCategoriesGiteePending();
    _saveData();
    notifyListeners();
  }

  /// 时间块是否计入目标进度（categoryId + label 双重匹配，兼容旧数据）
  bool slotMatchesTarget(TimeSlot slot, Target target) {
    if (!slot.recorded || slot.label == null) return false;
    if (target.categoryId.isNotEmpty &&
        slot.categoryId != null &&
        slot.categoryId!.isNotEmpty) {
      // categoryId 必须匹配
      if (slot.categoryId != target.categoryId) return false;

      // 查找目标对应的分类（使用缓存的 Map，O(1) 查找）
      final category = _categoryIdMap()[target.categoryId];

      // 如果目标名称等于分类名称（父分类目标），匹配该分类下所有子分类
      if (category != null && category.name == target.name) {
        return true;
      }

      // 否则匹配特定的子分类名称
      return slot.label == target.name;
    }
    // 兼容旧数据：仅匹配 label
    return slot.label == target.name;
  }

  /// 根据显示名称解析所属分类 ID（主分类名或子分类名）
  String? resolveCategoryIdForLabel(String label) {
    return _labelToCategoryIdMap()[label];
  }

  Map<String, String> _labelToCategoryIdMap() {
    if (_labelCategoryIdCache != null) return _labelCategoryIdCache!;

    final map = <String, String>{};
    for (final cat in _categories) {
      map[cat.name] = cat.id;
      for (final sub in cat.subCategories) {
        map[sub] = cat.id;
      }
    }
    _labelCategoryIdCache = map;
    return map;
  }

  void _invalidateLabelCategoryIdCache() {
    _labelCategoryIdCache = null;
    _categoryIdMapCache = null;
  }

  Map<String, Category> _categoryIdMap() {
    if (_categoryIdMapCache != null) return _categoryIdMapCache!;
    final map = <String, Category>{};
    for (final cat in _categories) {
      map[cat.id] = cat;
    }
    _categoryIdMapCache = map;
    return map;
  }

  void _propagateLabelRename(
      String categoryId, String oldLabel, String newLabel) {
    if (oldLabel == newLabel) return;

    _dailySlots.forEach((_, daySlots) {
      for (final slot in daySlots) {
        if (slot.categoryId == categoryId && slot.label == oldLabel) {
          slot.label = newLabel;
        }
      }
    });

    for (int i = 0; i < _targets.length; i++) {
      final target = _targets[i];
      if (target.categoryId == categoryId && target.name == oldLabel) {
        _targets[i] = target.copyWith(name: newLabel);
      }
    }

    for (int i = 0; i < _templates.length; i++) {
      final template = _templates[i];
      var changed = false;
      final newSlots = template.slots.map((entry) {
        if (entry.categoryId == categoryId && entry.label == oldLabel) {
          changed = true;
          return TemplateSlot(
            index: entry.index,
            label: newLabel,
            categoryId: entry.categoryId,
            colorArgb: entry.colorArgb,
          );
        }
        return entry;
      }).toList();
      if (changed) {
        _templates[i] = template.copyWith(slots: newSlots);
      }
    }

    // 重命名会影响所有日期的时间块、目标和模板
    _markAllSlotsDirty();
    _targetsDirty = true;
    _markTemplatesChanged();
    _targetStatsCache.invalidate();
    _invalidateLabelCategoryIdCache();
    _addTargetStatsChanged(); // 通知目标统计变化
  }

  void _migrateToCategoryIds() {
    var categoriesChanged = false;
    _categories = _categories.map((cat) {
      if (cat.id.isEmpty) {
        categoriesChanged = true;
        return cat.copyWith(
            id: DateTime.now().microsecondsSinceEpoch.toString());
      }
      return cat;
    }).toList();

    // 先让分类获得新 ID，再构建映射表
    if (categoriesChanged) _invalidateLabelCategoryIdCache();
    final labelMap = _labelToCategoryIdMap();

    var slotsChanged = false;
    _dailySlots.forEach((_, daySlots) {
      for (final slot in daySlots) {
        if (slot.recorded &&
            (slot.categoryId == null || slot.categoryId!.isEmpty) &&
            slot.label != null) {
          final cid = labelMap[slot.label!];
          if (cid != null) {
            slot.categoryId = cid;
            slotsChanged = true;
          }
        }
      }
    });

    var targetsChanged = false;
    for (int i = 0; i < _targets.length; i++) {
      final target = _targets[i];
      if (target.categoryId.isEmpty) {
        final cid = labelMap[target.name];
        if (cid != null) {
          _targets[i] = target.copyWith(categoryId: cid);
          targetsChanged = true;
        }
      }
    }

    if (categoriesChanged || slotsChanged || targetsChanged) {
      if (categoriesChanged) _markCategoriesChanged();
      if (slotsChanged) _markAllSlotsDirty();
      if (targetsChanged) _targetsDirty = true;
      _saveData();
    }
  }

  void _markCategoriesChanged() {
    _categoriesDirty = true;
    _categoriesRevision++;
  }

  void _markTemplatesChanged() {
    _templatesDirty = true;
    _templatesRevision++;
  }

  void _markSlotsDirty(String dateKey) {
    _slotsDirty.add(dateKey);
    _slotsRevision++;
  }

  void _markAllSlotsDirty() {
    _allSlotsDirty = true;
    _slotsRevision++;
  }

  // --- 数据持久化逻辑 ---

  Future<bool> _saveDataForRemoteViewTransition(int epoch) {
    return _saveData(
      mode: _ScheduleSaveMode.remoteViewTransition,
      remoteViewTransitionEpoch: epoch,
    );
  }

  Future<bool> _saveData({
    _ScheduleSaveSnapshot? snapshot,
    _ScheduleSaveMode mode = _ScheduleSaveMode.normal,
    int? remoteViewTransitionEpoch,
  }) async {
    bool canPersist() {
      if (mode == _ScheduleSaveMode.remoteViewTransition) {
        return remoteViewTransitionEpoch != null &&
            _canContinueRemoteViewPersistence(remoteViewTransitionEpoch);
      }
      return !_isSchedulePersistenceBlocked;
    }

    if (!_isScheduleReady) return false;
    if (mode == _ScheduleSaveMode.normal &&
        snapshot == null &&
        _scheduleOverwriteInProgress) {
      _deferredScheduleSaveRequested = true;
      return false;
    }
    if (!canPersist()) return false;
    if (mode == _ScheduleSaveMode.normal &&
        snapshot == null &&
        !await _prepareSchedulePersistence()) {
      return false;
    }
    if (!canPersist()) return false;
    if (_saveDataOverride != null) {
      final saved = await _saveDataOverride!();
      return saved && canPersist();
    }
    final previous = _ongoingSave;
    final requestRevision = ++_saveRequestRevision;
    // 串行化保存：等待上一个保存完成后再启动本次，
    // 避免并发读写导致整包写回时互相覆盖丢数据。
    final save = (previous ?? Future<bool>.value(true))
        .catchError((_) => false) // 上一个保存失败不阻断本次
        .then(
          (_) => _saveDataImpl(
            requestRevision,
            snapshot,
            mode: mode,
            remoteViewTransitionEpoch: remoteViewTransitionEpoch,
          ),
        );
    _ongoingSave = save;
    try {
      return await save;
    } finally {
      if (_ongoingSave == save) _ongoingSave = null;
    }
  }

  Future<bool> _saveDataImpl(
    int requestRevision,
    _ScheduleSaveSnapshot? snapshot, {
    required _ScheduleSaveMode mode,
    int? remoteViewTransitionEpoch,
  }) async {
    bool canPersist() {
      if (mode == _ScheduleSaveMode.remoteViewTransition) {
        return remoteViewTransitionEpoch != null &&
            _canContinueRemoteViewPersistence(remoteViewTransitionEpoch);
      }
      return !_isSchedulePersistenceBlocked;
    }

    if (!_isScheduleReady || !canPersist()) return false;
    if (mode == _ScheduleSaveMode.normal &&
        snapshot == null &&
        _scheduleOverwriteInProgress) {
      _deferredScheduleSaveRequested = true;
      return false;
    }
    if (snapshot != null) return _saveScheduleSnapshot(snapshot);

    // Invalidate stats cache on any data change (包括分类/目标结构变化)
    if (_slotsDirty.isNotEmpty ||
        _allSlotsDirty ||
        _categoriesDirty ||
        _targetsDirty) {
      _statsCache = null;
      _statsCacheKey = null;
      _occurrenceCache = null;
      _occurrenceCacheKey = null;
    }

    final prefs = await SharedPreferences.getInstance();
    if (!_isScheduleReady || !canPersist()) return false;

    // 1. 保存分类（仅在变化时）
    final categoriesDirtyAtStart = _categoriesDirty;
    if (categoriesDirtyAtStart) {
      List<String> catList =
          _categories.map((c) => json.encode(c.toJson())).toList();
      if (!canPersist() ||
          !await prefs.setStringList('categories', catList) ||
          !canPersist()) {
        return false;
      }
      // 分类删除墓碑（id → 删除时间戳）与文档时间戳随分类一并持久化
      if (!canPersist() ||
          !await prefs.setString(
              'deleted_categories', json.encode(_deletedCategories)) ||
          !canPersist()) {
        return false;
      }
      if (!canPersist() ||
          !await prefs.setInt(
              'categories_doc_updated_at', _categoriesDocUpdatedAt) ||
          !canPersist()) {
        return false;
      }
      if (_saveRequestRevision == requestRevision) {
        _categoriesDirty = false;
      }
    }

    // 2. 保存目标（仅在变化时）
    final targetsDirtyAtStart = _targetsDirty;
    if (targetsDirtyAtStart) {
      List<String> targetList =
          _targets.map((t) => json.encode(t.toJson())).toList();
      if (!canPersist() ||
          !await prefs.setStringList('targets', targetList) ||
          !canPersist()) {
        return false;
      }
      if (_saveRequestRevision == requestRevision) {
        _targetsDirty = false;
      }
    }

    // 3. 保存时间块（仅保存变化的日期）
    bool slotsChanged = false;
    final allSlotsDirtyAtStart = _allSlotsDirty;
    final dirtyDatesAtStart = Set<String>.from(_slotsDirty);
    if (allSlotsDirtyAtStart) {
      // 全量保存所有时间块
      Map<String, dynamic> slotsJson = {};
      _dailySlots.forEach((dateKey, daySlots) {
        final recordedSlots = _serializeRecordedSlots(daySlots);
        if (recordedSlots.isNotEmpty) {
          slotsJson[dateKey] = recordedSlots;
        }
      });
      // 大 JSON 编码移入后台 isolate，避免主线程阻塞
      final encoded = await compute(_encodeSlotsJson, slotsJson);
      if (!canPersist()) return false;
      if (!canPersist() ||
          !await prefs.setString('daily_slots', encoded) ||
          !canPersist()) {
        return false;
      }
      slotsChanged = true;
      if (_saveRequestRevision == requestRevision) {
        _allSlotsDirty = false;
        _slotsDirty.clear();
      }
    } else if (dirtyDatesAtStart.isNotEmpty) {
      // 增量保存：先对本次请求的脏日期做快照，成功后再清理，
      // 保存期间产生的新修改会保留给下一次保存。
      // 加载现有数据并合并
      String? slotsStr = prefs.getString('daily_slots');
      Map<String, dynamic> slotsJson = {};
      if (slotsStr != null) {
        try {
          slotsJson = json.decode(slotsStr) as Map<String, dynamic>;
        } catch (_) {}
      }
      // 更新变化的日期
      for (final dateKey in dirtyDatesAtStart) {
        final daySlots = _dailySlots[dateKey];
        if (daySlots != null) {
          final recordedSlots = _serializeRecordedSlots(daySlots);
          if (recordedSlots.isNotEmpty) {
            slotsJson[dateKey] = recordedSlots;
          } else {
            slotsJson.remove(dateKey);
          }
        } else {
          slotsJson.remove(dateKey);
        }
      }
      if (!canPersist() ||
          !await prefs.setString('daily_slots', json.encode(slotsJson)) ||
          !canPersist()) {
        return false;
      }
      slotsChanged = true;
      if (_saveRequestRevision == requestRevision) {
        _slotsDirty.removeAll(dirtyDatesAtStart);
      }
    }

    // 4. 日程模板（仅在变化时）
    final templatesDirtyAtStart = _templatesDirty;
    if (templatesDirtyAtStart) {
      if (!canPersist() ||
          !await prefs.setString(
            'schedule_templates',
            json.encode(_templates.map((t) => t.toJson()).toList()),
          ) ||
          !canPersist()) {
        return false;
      }
      if (_saveRequestRevision == requestRevision) {
        _templatesDirty = false;
      }
    }

    // 5. 已忽略的 Google 日历导入（仅在变化时）
    final calendarDirtyAtStart = _calendarDirty;
    if (calendarDirtyAtStart) {
      final ignoredJson = <String, dynamic>{};
      _ignoredCalendarImports.forEach((dateKey, ids) {
        if (ids.isNotEmpty) ignoredJson[dateKey] = ids.toList();
      });
      if (!canPersist() ||
          !await prefs.setString(
              'ignored_calendar_imports', json.encode(ignoredJson)) ||
          !canPersist()) {
        return false;
      }
      if (_saveRequestRevision == requestRevision) {
        _calendarDirty = false;
      }
    }

    // 6. 待同步日期（仅在变化时）
    final syncDirtyAtStart = _syncDirty;
    if (syncDirtyAtStart) {
      final allPendingDates = _pendingSyncState.allDates.toList()..sort();
      final giteePendingDates = pendingGiteeSyncDates.toList()..sort();
      final googlePendingDates = pendingGoogleSyncDates.toList()..sort();
      if (!canPersist() ||
          !await prefs.setStringList(
              'pending_gitee_sync_dates', giteePendingDates) ||
          !canPersist()) {
        return false;
      }
      if (!canPersist() ||
          !await prefs.setStringList(
              'pending_google_sync_dates', googlePendingDates) ||
          !canPersist()) {
        return false;
      }
      if (!canPersist() ||
          !await prefs.setStringList('pending_sync_dates', allPendingDates) ||
          !canPersist()) {
        return false;
      }
      if (_saveRequestRevision == requestRevision) {
        _syncDirty = false;
      }
    }

    // 7. 分类展开状态（仅变化时写，体积小）
    final expandChanged = _categoryExpandDirty;
    if (expandChanged) {
      if (!canPersist() ||
          !await prefs.setString(
              'category_expand_states', json.encode(_categoryExpandStates)) ||
          !canPersist()) {
        return false;
      }
      if (_saveRequestRevision == requestRevision) {
        _categoryExpandDirty = false;
      }
    }

    // 小组件只在 slots 或展开状态实际变化时刷新，
    // 避免每次保存（含无变化调用）都走平台通道
    if (slotsChanged || expandChanged) {
      await _refreshHomeWidget();
      if (!canPersist()) return false;
    }
    return true;
  }

  /// A committed overwrite journal is a pending cleanup transaction.  Normal
  /// saves must not overwrite its `after` snapshot: doing so would make the
  /// next startup unable to tell whether the committed data is recoverable.
  /// Retry cleanup first, and leave the whole save untouched if it is still
  /// ambiguous.
  Future<bool> _prepareSchedulePersistence() async {
    if (!_scheduleOverwriteJournalCleanupPending) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_isDisposed || _initializationFailed) return false;
      final encoded = prefs.getString(_scheduleOverwriteJournalKey);
      if (encoded == null) {
        _scheduleOverwriteJournalCleanupPending = false;
        return true;
      }
      final journal = _ScheduleOverwriteJournal.fromEncoded(encoded);
      if (journal == null ||
          journal.phase != _ScheduleOverwriteJournal.committed ||
          !_schedulePreferencesMatch(prefs, journal.after)) {
        _markInitializationFailed('覆盖日程提交日志与本地数据不一致');
        return false;
      }
      if (!await _removeScheduleOverwriteJournal(prefs)) {
        _addScheduleSyncStatus('覆盖日程清理未完成，已暂停本地保存');
        return false;
      }
      if (_isDisposed || _initializationFailed) return false;
      _scheduleOverwriteJournalCleanupPending = false;
      return true;
    } catch (e) {
      debugPrint('覆盖日程提交日志重试清理失败: $e');
      _addScheduleSyncStatus('覆盖日程清理未完成，已暂停本地保存');
      return false;
    }
  }

  /// Persist an overwrite candidate through the same [_ongoingSave] chain as
  /// normal saves. Every await is guarded so an edit or identity switch that
  /// occurs while this request waits cannot advance the candidate further.
  ///
  /// These four keys describe one schedule snapshot. Unlike ordinary dirty
  /// saves, a partial overwrite cannot be retained: on any failed write or
  /// validity check, restore and verify the complete old snapshot.
  Future<bool> _saveScheduleSnapshot(_ScheduleSaveSnapshot snapshot) async {
    if (!snapshot.isStillValid()) return false;
    final prefs = await SharedPreferences.getInstance();
    if (!snapshot.isStillValid()) return false;

    final slotsJson = <String, dynamic>{};
    snapshot.dailySlots.forEach((dateKey, daySlots) {
      final recorded = _serializeRecordedSlots(daySlots);
      if (recorded.isNotEmpty) slotsJson[dateKey] = recorded;
    });
    final allPendingDates = {
      ...snapshot.giteePendingDates,
      ...snapshot.googlePendingDates,
    }.toList()
      ..sort();
    final giteeDates = snapshot.giteePendingDates.toList()..sort();
    final googleDates = snapshot.googlePendingDates.toList()..sort();

    final replacement = <String, Object?>{
      'daily_slots': json.encode(slotsJson),
      'pending_gitee_sync_dates': giteeDates,
      'pending_google_sync_dates': googleDates,
      'pending_sync_dates': allPendingDates,
    };
    final previous = _captureSchedulePreferences(prefs, replacement.keys);
    final replacementSnapshot = _SchedulePreferencesSnapshot(replacement);
    final preparedJournal = _ScheduleOverwriteJournal(
      phase: _ScheduleOverwriteJournal.prepared,
      before: previous,
      after: replacementSnapshot,
    );
    var journalWritten = false;
    Future<void> rollbackOrBlock(_ScheduleOverwriteJournal journal) async {
      if (_isDisposed) return;
      if (!await _rollbackScheduleOverwriteJournal(prefs, journal)) {
        _markInitializationFailed('覆盖日程回滚无法确认本地数据，请重启应用恢复');
      }
    }

    try {
      // The journal write itself can have an ambiguous platform outcome. Mark
      // the attempt before awaiting so a thrown/false result is compensated.
      journalWritten = true;
      if (!await _writeScheduleOverwriteJournal(prefs, preparedJournal)) {
        await rollbackOrBlock(preparedJournal);
        return false;
      }
      for (final entry in replacement.entries) {
        if (!snapshot.isStillValid()) {
          await rollbackOrBlock(preparedJournal);
          return false;
        }
        // A platform exception can occur after its persistent side effect, so
        // mark the attempt before awaiting and compensate on every failure.
        if (!await _writeSchedulePreference(prefs, entry.key, entry.value) ||
            !snapshot.isStillValid()) {
          await rollbackOrBlock(preparedJournal);
          return false;
        }
      }
      if (!snapshot.isStillValid() ||
          !_schedulePreferencesMatch(prefs, replacementSnapshot)) {
        await rollbackOrBlock(preparedJournal);
        return false;
      }

      // The committed marker is written before the in-memory replacement.
      // A process death after this point must keep the new disk snapshot,
      // rather than let startup restore the old one.
      final committedJournal = preparedJournal.withPhase(
        _ScheduleOverwriteJournal.committed,
      );
      if (!await _writeScheduleOverwriteJournal(prefs, committedJournal)) {
        await rollbackOrBlock(preparedJournal);
        return false;
      }
      _scheduleSnapshotJournalPhaseObserver?.call(
        _ScheduleOverwriteJournal.committed,
      );
      if (!snapshot.isStillValid()) {
        await rollbackOrBlock(committedJournal);
        return false;
      }

      // Keep the committed journal until the caller has published the same
      // replacement into memory.  Cleanup is deliberately a separate phase.
      return true;
    } catch (e) {
      debugPrint('覆盖快照写入失败: $e');
    }

    if (journalWritten) {
      final journal = _ScheduleOverwriteJournal.fromEncoded(
        prefs.getString(_scheduleOverwriteJournalKey) ?? '',
      );
      if (journal != null) {
        await rollbackOrBlock(journal);
      }
    }
    return false;
  }

  Future<bool> _writeScheduleOverwriteJournal(
    SharedPreferences prefs,
    _ScheduleOverwriteJournal journal,
  ) async {
    final encoded = journal.encode();
    final written = await prefs.setString(
      _scheduleOverwriteJournalKey,
      encoded,
    );
    if (_isDisposed) return false;
    return written && prefs.getString(_scheduleOverwriteJournalKey) == encoded;
  }

  bool _schedulePreferencesMatch(
    SharedPreferences prefs,
    _SchedulePreferencesSnapshot snapshot,
  ) {
    return snapshot.values.entries.every(
      (entry) => _schedulePreferenceValuesEqual(
        prefs.get(entry.key),
        entry.value,
      ),
    );
  }

  Future<bool> _rollbackScheduleOverwriteJournal(
    SharedPreferences prefs,
    _ScheduleOverwriteJournal journal,
  ) async {
    final prepared = journal.phase == _ScheduleOverwriteJournal.prepared
        ? journal
        : journal.withPhase(_ScheduleOverwriteJournal.prepared);
    try {
      if (journal.phase == _ScheduleOverwriteJournal.committed &&
          !_schedulePreferencesMatch(prefs, journal.after)) {
        debugPrint('覆盖快照回滚前发现磁盘已不是 committed 快照，保留恢复日志');
        return false;
      }
      // Never restore old values while a committed marker is visible.  If the
      // process stops during compensation, startup must know to restore old.
      if (!await _writeScheduleOverwriteJournal(prefs, prepared)) {
        return false;
      }
      if (!await _restoreSchedulePreferences(prefs, prepared.before)) {
        debugPrint('覆盖快照回滚失败，保留恢复日志');
        return false;
      }
      if (!_schedulePreferencesMatch(prefs, prepared.before)) {
        debugPrint('覆盖快照回滚后磁盘校验失败，保留恢复日志');
        return false;
      }
      final removed = await prefs.remove(_scheduleOverwriteJournalKey);
      if (!removed || prefs.containsKey(_scheduleOverwriteJournalKey)) {
        debugPrint('覆盖快照恢复后无法清理恢复日志');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('覆盖快照回滚失败: $e');
      return false;
    }
  }

  Future<bool> _rollbackCommittedScheduleOverwrite() async {
    if (_isDisposed) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_isDisposed) return false;
      final encoded = prefs.getString(_scheduleOverwriteJournalKey);
      if (encoded == null) return false;
      final journal = _ScheduleOverwriteJournal.fromEncoded(encoded);
      if (journal == null ||
          journal.phase != _ScheduleOverwriteJournal.committed ||
          !_schedulePreferencesMatch(prefs, journal.after)) {
        return false;
      }
      final rolledBack =
          await _rollbackScheduleOverwriteJournal(prefs, journal);
      if (_isDisposed) return false;
      if (!rolledBack) {
        _markInitializationFailed('覆盖日程回滚无法确认本地数据，请重启应用恢复');
      }
      return rolledBack;
    } catch (e) {
      debugPrint('覆盖快照提交后回滚失败: $e');
      return false;
    }
  }

  Future<bool> _finalizeScheduleOverwriteJournal({
    bool Function()? isStillValid,
  }) async {
    if (_isDisposed) return false;
    SharedPreferences? prefs;
    _ScheduleOverwriteJournal? journal;
    try {
      prefs = await SharedPreferences.getInstance();
      if (_isDisposed) return false;
      if (_initializationFailed) {
        _scheduleOverwriteJournalCleanupPending = true;
        return false;
      }
      final encoded = prefs.getString(_scheduleOverwriteJournalKey);
      if (encoded == null) return true;
      journal = _ScheduleOverwriteJournal.fromEncoded(encoded);
      if (journal == null ||
          journal.phase != _ScheduleOverwriteJournal.committed ||
          !_schedulePreferencesMatch(prefs, journal.after)) {
        debugPrint('覆盖快照提交日志无法验证，保留日志供启动恢复');
        _markInitializationFailed('覆盖日程提交日志与本地数据不一致');
        return false;
      }
      if (isStillValid != null && !isStillValid()) {
        _scheduleOverwriteJournalCleanupPending = true;
        return false;
      }
      final removed = await _removeScheduleOverwriteJournal(prefs);
      if (_isDisposed) return false;
      if (!removed) {
        _scheduleOverwriteJournalCleanupPending = true;
        if (!await _retainCommittedScheduleOverwriteJournal(prefs, journal)) {
          _markInitializationFailed('覆盖日程提交日志无法保留，请重启应用恢复');
        }
        debugPrint('覆盖快照提交后无法清理日志，保留 committed 日志');
        return false;
      }
      // A mutation request may have been rejected while the real remove was
      // awaiting.  The key is already gone, so do not recreate the journal;
      // report failure while leaving the committed snapshot owned by the
      // original identity and recoverable on restart.
      if (isStillValid != null && !isStillValid()) {
        _scheduleOverwriteJournalCleanupPending = false;
        return false;
      }
      // The new schedule is already committed in memory and on disk.  Once
      // the remove has been confirmed, cleanup is complete even if the user
      // edits or switches identity while the platform await was in flight.
      // Never recreate a journal after a successful remove: doing so could
      // fail after the key has been deleted and leave an unrecoverable state.
      _scheduleOverwriteJournalCleanupPending = false;
      return true;
    } catch (e) {
      debugPrint('覆盖快照提交后清理日志失败，保留 committed 日志: $e');
      if (_isDisposed) return false;
      _scheduleOverwriteJournalCleanupPending = true;
      if (prefs != null && journal != null) {
        if (!await _retainCommittedScheduleOverwriteJournal(prefs, journal)) {
          _markInitializationFailed('覆盖日程提交日志无法保留，请重启应用恢复');
        }
      }
      return false;
    }
  }

  Future<bool> _retainCommittedScheduleOverwriteJournal(
    SharedPreferences prefs,
    _ScheduleOverwriteJournal journal,
  ) async {
    try {
      return await _writeScheduleOverwriteJournal(prefs, journal);
    } catch (e) {
      debugPrint('覆盖快照提交日志保留失败: $e');
      return false;
    }
  }

  Future<bool> _removeScheduleOverwriteJournal(SharedPreferences prefs) async {
    final removed = _scheduleSnapshotJournalRemoveOverride == null
        ? await prefs.remove(_scheduleOverwriteJournalKey)
        : await _scheduleSnapshotJournalRemoveOverride!();
    return removed && !prefs.containsKey(_scheduleOverwriteJournalKey);
  }

  _SchedulePreferencesSnapshot _captureSchedulePreferences(
    SharedPreferences prefs,
    Iterable<String> keys,
  ) {
    final values = <String, Object?>{};
    for (final key in keys) {
      final value = prefs.get(key);
      values[key] = value is List ? List<Object?>.from(value) : value;
    }
    return _SchedulePreferencesSnapshot(values);
  }

  Future<bool> _writeSchedulePreference(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    final written = switch (value) {
      String value => await prefs.setString(key, value),
      List<Object?> value =>
        await prefs.setStringList(key, value.cast<String>()),
      _ => false,
    };
    if (_isDisposed) return false;
    if (written) _scheduleSnapshotWriteObserver?.call(key);
    return written && _schedulePreferenceValuesEqual(prefs.get(key), value);
  }

  Future<bool> _restoreSchedulePreferences(
    SharedPreferences prefs,
    _SchedulePreferencesSnapshot snapshot,
  ) async {
    var restored = true;
    for (final entry in snapshot.values.entries) {
      if (_isDisposed) return false;
      try {
        final didRestore = entry.value == null
            ? await prefs.remove(entry.key)
            : await _writeSchedulePreference(prefs, entry.key, entry.value);
        if (_isDisposed) return false;
        if (!didRestore ||
            !_schedulePreferenceValuesEqual(
                prefs.get(entry.key), entry.value)) {
          restored = false;
        }
      } catch (e) {
        debugPrint('恢复覆盖快照 ${entry.key} 失败: $e');
        restored = false;
      }
    }
    return restored;
  }

  bool _schedulePreferenceValuesEqual(Object? left, Object? right) {
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (left[index] != right[index]) return false;
      }
      return true;
    }
    return left == right;
  }

  Future<void> _recoverScheduleOverwriteJournal(SharedPreferences prefs) async {
    if (_isDisposed) return;
    final encoded = prefs.getString(_scheduleOverwriteJournalKey);
    if (encoded == null) return;
    final journal = _ScheduleOverwriteJournal.fromEncoded(encoded);
    if (journal == null) {
      throw StateError('覆盖日程恢复日志格式无效');
    }

    if (journal.phase == _ScheduleOverwriteJournal.committed) {
      // A committed journal is the source of truth after a crash between
      // memory publication and cleanup.  Never roll it back to old values.
      if (!_schedulePreferencesMatch(prefs, journal.after)) {
        throw StateError('覆盖日程已提交日志与磁盘快照不一致');
      }
    } else if (!await _restoreSchedulePreferences(prefs, journal.before)) {
      throw StateError('覆盖日程恢复日志无法恢复');
    }
    if (_isDisposed) return;
    if (!await prefs.remove(_scheduleOverwriteJournalKey) ||
        prefs.containsKey(_scheduleOverwriteJournalKey)) {
      throw StateError('覆盖日程恢复日志无法清理');
    }
  }

  Future<void> _refreshHomeWidget() async {
    // 桌面小组件仅 Android 支持，Windows 无实现，直接跳过避免 MissingPluginException
    if (isDesktopPlatform || !_isScheduleReady) return;
    try {
      await HomeWidgetService.updateFromDay(
        slots: slots,
        date: _currentDate,
        pendingSync: hasPendingSyncForCurrentDate,
      );
      if (!_isScheduleReady) return;
    } catch (e) {
      debugPrint('更新桌面小组件失败: $e');
    }
  }

  Map<String, dynamic> toBackupMap() {
    final slotsJson = <String, dynamic>{};
    _dailySlots.forEach((dateKey, daySlots) {
      final recorded = _serializeRecordedSlots(daySlots);
      if (recorded.isNotEmpty) {
        slotsJson[dateKey] = recorded;
      }
    });

    final ignoredJson = <String, dynamic>{};
    _ignoredCalendarImports.forEach((dateKey, ids) {
      if (ids.isNotEmpty) {
        ignoredJson[dateKey] = ids.toList();
      }
    });

    return {
      'version': backupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'categories': _categories
          .map((c) => {
                'id': c.id,
                'name': c.name,
                'color': c.color.toARGB32(),
                'subCategories': c.subCategories,
                'hiddenSubCategories': c.hiddenSubCategories,
              })
          .toList(),
      'targets': _targets.map((t) => t.toJson()).toList(),
      'dailySlots': slotsJson,
      'scheduleTemplates': _templates.map((t) => t.toJson()).toList(),
      'ignoredCalendarImports': ignoredJson,
      'pendingSyncDates': _pendingSyncState.allDates.toList(),
      'pendingGiteeSyncDates': pendingGiteeSyncDates.toList(),
      'pendingGoogleSyncDates': pendingGoogleSyncDates.toList(),
    };
  }

  String exportBackupJson() {
    return const JsonEncoder.withIndent('  ').convert(toBackupMap());
  }

  BackupPreview? previewBackupJson(String jsonStr) {
    try {
      final data = _parseBackupRoot(jsonStr);
      final categories = data['categories'];
      final targets = data['targets'];
      final dailySlots = data['dailySlots'];
      final templates = data['scheduleTemplates'];

      if (categories is! List || dailySlots is! Map) {
        return null;
      }

      return BackupPreview(
        exportedAt: data['exportedAt'] as String?,
        dayCount: dailySlots.length,
        targetCount: targets is List ? targets.length : 0,
        categoryCount: categories.length,
        templateCount: templates is List ? templates.length : 0,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> importBackupJson(String jsonStr) async {
    if (!_initialLoadCompleter.isCompleted) {
      await _initialLoadCompleter.future;
    }
    if (!_allowScheduleMutation()) return;
    final data = _parseBackupRoot(jsonStr);
    _applyBackupMap(data);
    _migrateToCategoryIds();
    // 导入是全量操作，设置所有脏标记
    _markCategoriesChanged();
    _targetsDirty = true;
    _markAllSlotsDirty();
    _markTemplatesChanged();
    _calendarDirty = true;
    _syncDirty = true;
    final saved = await _saveData();
    if (!_isDisposed && saved) notifyListeners();
  }

  Map<String, dynamic> _parseBackupRoot(String jsonStr) {
    final decoded = json.decode(jsonStr);
    if (decoded is! Map) {
      throw const FormatException('备份文件格式无效');
    }
    final data = Map<String, dynamic>.from(decoded);

    final version = data['version'];
    if (version is num && version > backupVersion) {
      throw FormatException('备份版本过新（v$version），请先升级 App');
    }
    if (data['categories'] is! List || data['dailySlots'] is! Map) {
      throw const FormatException('备份文件缺少必要数据');
    }
    return data;
  }

  void _applyBackupMap(Map<String, dynamic> data) {
    // 先解析到临时容器，全部完成后再替换真实状态，避免畸形备份造成半导入。
    final parsedCategories = <Category>[];
    for (final e in data['categories'] as List) {
      try {
        final map = Map<String, dynamic>.from(e as Map);
        parsedCategories.add(Category.fromJson(map));
      } catch (err) {
        debugPrint("导入分类数据出错: $err");
      }
    }
    if (!parsedCategories.any((c) => c.name == temporaryCategoryName)) {
      parsedCategories.add(Category(
        name: temporaryCategoryName,
        color: const Color(0xFF9E9E9E),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }

    final parsedTargets = <Target>[];
    final targets = data['targets'];
    if (targets is List) {
      for (final e in targets) {
        try {
          parsedTargets
              .add(Target.fromJson(Map<String, dynamic>.from(e as Map)));
        } catch (err) {
          debugPrint("导入目标数据出错: $err");
        }
      }
    }

    final parsedDailySlots = <String, List<TimeSlot>>{};
    try {
      _loadDailySlotsFromJson(
        Map<String, dynamic>.from(data['dailySlots'] as Map),
        destination: parsedDailySlots,
      );
    } catch (err) {
      debugPrint("导入时间块数据出错: $err");
    }

    final parsedTemplates = <ScheduleTemplate>[];
    final templates = data['scheduleTemplates'];
    if (templates is List) {
      for (final e in templates) {
        try {
          parsedTemplates.add(
              ScheduleTemplate.fromJson(Map<String, dynamic>.from(e as Map)));
        } catch (err) {
          debugPrint("导入模板数据出错: $err");
        }
      }
    }

    final parsedIgnored = <String, Set<String>>{};
    final ignored = data['ignoredCalendarImports'];
    if (ignored is Map) {
      ignored.forEach((dateKey, value) {
        if (value is List) {
          final normalizedKey = _normalizeDateKey(dateKey.toString());
          parsedIgnored[normalizedKey] = value.whereType<String>().toSet();
        }
      });
    }

    final parsedPending = <String>{};
    final pending = data['pendingSyncDates'];
    if (pending is List) {
      parsedPending.addAll(
        pending.map((e) => _normalizeDateKey(e.toString())),
      );
    }

    final parsedGiteePending = <String>{};
    final giteePending = data['pendingGiteeSyncDates'];
    if (giteePending is List) {
      parsedGiteePending.addAll(
        giteePending.map((e) => _normalizeDateKey(e.toString())),
      );
    }

    final parsedGooglePending = <String>{};
    final googlePending = data['pendingGoogleSyncDates'];
    if (googlePending is List) {
      parsedGooglePending.addAll(
        googlePending.map((e) => _normalizeDateKey(e.toString())),
      );
    }
    final hasSplitPendingState = giteePending is List || googlePending is List;
    final legacyPendingState = PendingSyncState.fromLegacy(
      parsedPending,
      desktop: isDesktopPlatform,
    );

    _categories = parsedCategories;
    _targets
      ..clear()
      ..addAll(parsedTargets);
    _dailySlots
      ..clear()
      ..addAll(parsedDailySlots);
    _templates
      ..clear()
      ..addAll(parsedTemplates);
    _ignoredCalendarImports
      ..clear()
      ..addAll(parsedIgnored);
    _pendingSyncState.replace(
      giteeDates: hasSplitPendingState
          ? parsedGiteePending
          : legacyPendingState.giteeDates,
      googleDates: hasSplitPendingState
          ? parsedGooglePending
          : legacyPendingState.googleDates,
    );
  }

  void _ensureTempCategory() {
    if (!_categories.any((c) => c.name == temporaryCategoryName)) {
      _categories.add(Category(
        name: temporaryCategoryName,
        color: const Color(0xFF9E9E9E),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
  }

  List<Category> _defaultCategories() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return [
      Category(
          name: '学习',
          color: const Color(0xFFD4AF37),
          subCategories: ['阅读', '编程'],
          updatedAt: nowMs),
      Category(
          name: '工作',
          color: const Color(0xFF9CB86A),
          subCategories: ['会议', '文档'],
          updatedAt: nowMs),
      Category(name: '运动', color: const Color(0xFF4A90E2), updatedAt: nowMs),
      Category(
          name: temporaryCategoryName,
          color: const Color(0xFF9E9E9E),
          updatedAt: nowMs),
    ];
  }

  void _loadDailySlotsFromJson(
    Map<String, dynamic> slotsJson, {
    Map<String, List<TimeSlot>>? destination,
  }) {
    final target = destination ?? _dailySlots;
    slotsJson.forEach((rawKey, value) {
      final dateKey = _normalizeDateKey(rawKey);
      // 若同一日期同时存在旧格式和新格式 key，合并两份数据（不丢失任一槽位）
      final existing = target[dateKey];
      final daySlots = existing ?? _generateInitialSlots();
      for (final item in value is List ? value : const <dynamic>[]) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final idx = _parseInt(map['i']);
        if (idx == null) continue;
        if (idx >= 0 && idx < daySlots.length) {
          if (map['del'] == true) {
            // 删除墓碑：槽位保持清空，仅恢复删除时间
            daySlots[idx].isFromCalendar = map['fc'] == true;
            final delTs = _parseInt(map['ts']);
            if (delTs != null && delTs > 0) {
              daySlots[idx].deletedAt =
                  DateTime.fromMillisecondsSinceEpoch(delTs);
            }
            continue;
          }
          daySlots[idx].recorded = true;
          daySlots[idx].label = map['l'] as String?;
          daySlots[idx].categoryId = map['cid'] as String?;
          if (map['c'] != null) {
            final colorVal = _parseInt(map['c']);
            if (colorVal != null) {
              daySlots[idx].color = Color(colorVal);
            }
          }
          if (map['fc'] == true) {
            daySlots[idx].isFromCalendar = true;
          }
          if (map['eid'] != null) {
            daySlots[idx].calendarEventId = map['eid'] as String?;
          }
          final modifiedTs = _parseInt(map['ts']);
          if (modifiedTs != null && modifiedTs > 0) {
            daySlots[idx].modifiedAt =
                DateTime.fromMillisecondsSinceEpoch(modifiedTs);
          }
        }
      }
      target[dateKey] = daySlots;
    });
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    if (_isDisposed) return;
    await _recoverScheduleOverwriteJournal(prefs);
    if (_isDisposed) return;

    // 1. 加载分类
    List<String>? catList = prefs.getStringList('categories');
    if (catList != null && catList.isNotEmpty) {
      _categories = [];
      var needMigration = false;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final str in catList) {
        try {
          final map = json.decode(str) as Map<String, dynamic>;
          var cat = Category.fromJson(map);
          // 旧数据没有时间戳：统一迁移为当前时间，避免首次同步两端同为 0 覆盖
          if (cat.updatedAt <= 0) {
            cat = cat.copyWith(updatedAt: nowMs);
            needMigration = true;
          }
          _categories.add(cat);
        } catch (e) {
          debugPrint("加载分类数据出错: $e");
        }
      }
      if (needMigration) _categoriesDirty = true;
      _ensureTempCategory();
    } else {
      _categories = _defaultCategories();
    }

    // 分类删除墓碑（id → 删除时间戳）与文档时间戳
    final deletedStr = prefs.getString('deleted_categories');
    if (deletedStr != null) {
      try {
        final decoded = json.decode(deletedStr);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final ts = (v is num) ? v.toInt() : int.tryParse(v.toString());
            if (k is String && ts != null && ts > 0) {
              _deletedCategories[k] = ts;
            }
          });
        }
      } catch (_) {}
    }
    _categoriesDocUpdatedAt = prefs.getInt('categories_doc_updated_at') ?? 0;

    // 2. 加载目标
    List<String>? targetList = prefs.getStringList('targets');
    if (targetList != null) {
      _targets.clear();
      for (final str in targetList) {
        try {
          _targets.add(Target.fromJson(json.decode(str)));
        } catch (e) {
          debugPrint("加载目标数据出错: $e");
        }
      }
    }

    // 3. 加载时间块
    String? slotsStr = prefs.getString('daily_slots');
    if (slotsStr != null) {
      try {
        _dailySlots.clear();
        _loadDailySlotsFromJson(json.decode(slotsStr) as Map<String, dynamic>);
      } catch (e) {
        debugPrint("加载时间块数据出错: $e");
      }
    }

    // 4. 日程模板
    final templatesStr = prefs.getString('schedule_templates');
    if (templatesStr != null) {
      try {
        final list = json.decode(templatesStr) as List<dynamic>;
        _templates
          ..clear()
          ..addAll(list
              .map((e) => ScheduleTemplate.fromJson(e as Map<String, dynamic>))
              .toList());
      } catch (e) {
        debugPrint("加载模板数据出错: $e");
      }
    }

    // 5. 已忽略的 Google 日历导入
    final ignoredStr = prefs.getString('ignored_calendar_imports');
    if (ignoredStr != null) {
      try {
        final ignoredJson = json.decode(ignoredStr) as Map<String, dynamic>;
        _ignoredCalendarImports.clear();
        ignoredJson.forEach((dateKey, value) {
          final normalizedKey = _normalizeDateKey(dateKey);
          final existing = _ignoredCalendarImports[normalizedKey];
          final set = existing ?? <String>{};
          set.addAll((value as List<dynamic>).cast<String>());
          _ignoredCalendarImports[normalizedKey] = set;
        });
      } catch (e) {
        debugPrint("加载忽略日历列表出错: $e");
      }
    }

    // 6. 待同步日期
    final legacyPending = (prefs.getStringList('pending_sync_dates') ?? [])
        .map(_normalizeDateKey)
        .toSet();
    final storedGiteePending = prefs.getStringList('pending_gitee_sync_dates');
    final storedGooglePending =
        prefs.getStringList('pending_google_sync_dates');
    final legacyState = PendingSyncState.fromLegacy(
      legacyPending,
      desktop: isDesktopPlatform,
    );
    _pendingSyncState.replace(
      giteeDates:
          (storedGiteePending ?? legacyState.giteeDates).map(_normalizeDateKey),
      googleDates: (storedGooglePending ?? legacyState.googleDates)
          .map(_normalizeDateKey),
    );
    _googleCalendarSyncEnabled = !_supportsGoogleCalendarSync
        ? false
        : (prefs.getBool('google_calendar_sync_enabled') ?? true);
    _scheduleUser = DiaryKindX.fromCode(prefs.getString(_scheduleUserKey));

    // 7. 分类展开状态（key 为 Category ID）
    final expandStr = prefs.getString('category_expand_states');
    if (expandStr != null) {
      try {
        final expandJson = json.decode(expandStr) as Map<String, dynamic>;
        _categoryExpandStates = expandJson.map(
          (key, value) => MapEntry(key, value as bool),
        );
      } catch (e) {
        debugPrint("加载分类展开状态出错: $e");
      }
    }

    _migrateToCategoryIds();
  }

  /// 移动子分类到另一个分类
  void moveSubCategory(
      String fromCategoryId, String toCategoryId, String subName) {
    if (!_allowScheduleMutation()) return;
    // 1. 更新分类结构
    final fromIndex = _categories.indexWhere((c) => c.id == fromCategoryId);
    final toIndex = _categories.indexWhere((c) => c.id == toCategoryId);
    if (fromIndex == -1 || toIndex == -1) return;

    final fromCat = _categories[fromIndex];
    final toCat = _categories[toIndex];

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _categories[fromIndex] = fromCat.copyWith(
      subCategories: fromCat.subCategories.where((s) => s != subName).toList(),
      updatedAt: nowMs,
    );
    _categories[toIndex] = toCat.copyWith(
      subCategories: [...toCat.subCategories, subName],
      updatedAt: nowMs,
    );

    // 2. 更新所有相关时间块的 categoryId
    _dailySlots.forEach((_, daySlots) {
      for (final slot in daySlots) {
        if (slot.categoryId == fromCategoryId && slot.label == subName) {
          slot.categoryId = toCategoryId;
        }
      }
    });

    // 3. 更新目标的 categoryId（如果关联了这个子分类）
    for (int i = 0; i < _targets.length; i++) {
      final target = _targets[i];
      if (target.categoryId == fromCategoryId && target.name == subName) {
        _targets[i] = target.copyWith(categoryId: toCategoryId);
      }
    }

    // 4. 通知 UI 刷新
    _markCategoriesChanged();
    _markCategoriesGiteePending();
    _targetsDirty = true;
    _markAllSlotsDirty();
    _invalidateLabelCategoryIdCache();
    _targetStatsCache.invalidate();
    _addTargetStatsChanged();
    _saveData();
    notifyListeners();
  }

  void reorderCategories(int oldIndex, int newIndex) {
    if (!_allowScheduleMutation()) return;
    final Category item = _categories.removeAt(oldIndex);
    _categories.insert(newIndex, item);

    // 排序不改变分类自身时间戳，但需更新文档时间戳以传播顺序
    _categoriesDocUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    _markCategoriesChanged(); // 标记分类为脏
    _markCategoriesGiteePending();
    notifyListeners();
    _saveData();
  }

  void deleteCategory(int index) {
    if (!_allowScheduleMutation()) return;
    final categoryId = _categories[index].id;
    // 写入带时间戳的删除墓碑，防止另一端已同步的分支复活
    _deletedCategories[categoryId] = DateTime.now().millisecondsSinceEpoch;
    _categories.removeAt(index);
    _markCategoriesChanged();
    _markCategoriesGiteePending();
    _invalidateLabelCategoryIdCache();

    // Clean up orphaned slot references
    for (final entry in _dailySlots.entries) {
      for (final slot in entry.value) {
        if (slot.categoryId == categoryId) {
          slot.categoryId = null;
        }
      }
    }

    // Remove targets referencing this category
    _targets.removeWhere((t) => t.categoryId == categoryId);
    _targetsDirty = true;

    notifyListeners();
    _saveData();
    _addTargetStatsChanged();
  }

  void addTarget(Target target) {
    if (!_allowScheduleMutation()) return;
    _targets.add(target);
    _targetsDirty = true;
    _saveData();
    notifyListeners();
    _addTargetStatsChanged(); // 通知目标统计变化
  }

  void updateTarget(Target newTarget) {
    if (!_allowScheduleMutation()) return;
    int index = _targets.indexWhere((t) => t.id == newTarget.id);
    if (index != -1) {
      _targets[index] = newTarget;
      _targetsDirty = true;
      _saveData();
      notifyListeners();
      _addTargetStatsChanged(); // 通知目标统计变化
    }
  }

  void deleteTarget(Target target) {
    if (!_allowScheduleMutation()) return;
    _targets.remove(target);
    _targetsDirty = true;
    _saveData();
    notifyListeners();
    _addTargetStatsChanged(); // 通知目标统计变化
  }

  void reorderTargets(int oldIndex, int newIndex) {
    if (!_allowScheduleMutation()) return;
    final Target item = _targets.removeAt(oldIndex);
    _targets.insert(newIndex, item);
    _targetsDirty = true; // 标记目标为脏
    _saveData();
    notifyListeners();
  }

  /// 获取时间点目标在指定日期的状态
  TimePointStatus getTimePointStatus(Target target, DateTime date) {
    final dateKey = _getDateKey(date);
    final daySlots = _dailySlots[dateKey];
    if (daySlots == null) return TimePointStatus.notDone;

    // 1. 筛选匹配目标的记录
    var slots = daySlots.where((s) => slotMatchesTarget(s, target)).toList();
    if (slots.isEmpty) return TimePointStatus.notDone;

    // 2. 有效时间区间过滤（如果设置了）
    if (target.startTime.isNotEmpty && target.endTime.isNotEmpty) {
      int startMins = _parseTime(target.startTime);
      int endMins = _parseTime(target.endTime);
      slots = slots.where((s) {
        int t = s.hour * 60 + s.minute10 * 10;
        return t >= startMins && t < endMins;
      }).toList();
    }

    if (slots.isEmpty) return TimePointStatus.notDone;

    // 3. 取最早记录和目标时间比较
    int targetMins = _parseTime(target.targetTime);
    int earliestMins = slots
        .map((s) => s.hour * 60 + s.minute10 * 10)
        .reduce((a, b) => a < b ? a : b);

    bool isOnTime;
    if (target.compareType.contains("前") || target.compareType.contains("少")) {
      isOnTime = earliestMins <= targetMins;
    } else {
      isOnTime = earliestMins >= targetMins;
    }

    return isOnTime ? TimePointStatus.onTime : TimePointStatus.late;
  }

  int getTargetPersistenceDays(Target target) {
    int count = 0;
    _dailySlots.forEach((dateKey, daySlots) {
      if (target.type == TargetType.timePoint) {
        final dateParts = dateKey.split('-');
        if (dateParts.length < 3) return;
        final y = int.tryParse(dateParts[0]);
        final m = int.tryParse(dateParts[1]);
        final d = int.tryParse(dateParts[2]);
        if (y == null || m == null || d == null) return;
        final date = DateTime(y, m, d);
        if (getTimePointStatus(target, date) == TimePointStatus.onTime) {
          count++;
        }
      } else {
        if (daySlots.any((s) => slotMatchesTarget(s, target))) {
          count++;
        }
      }
    });
    return count;
  }

  // 获取目标的历史记录，合并连续时间块
  Map<String, List<String>> getTargetHistory(Target target) {
    Map<String, List<String>> history = {};

    // 1. 找出所有包含该目标记录的日期
    List<String> validDates = _dailySlots.keys.where((dateKey) {
      return _dailySlots[dateKey]!.any((s) => slotMatchesTarget(s, target));
    }).toList();

    // 2. 按日期倒序排列 (最新的在前面)
    validDates.sort((a, b) {
      DateTime? dA = _parseDateKey(a);
      DateTime? dB = _parseDateKey(b);
      if (dA == null || dB == null) return 0;
      return dB.compareTo(dA);
    });

    // 3. 生成时间段字符串
    for (String dateKey in validDates) {
      List<TimeSlot>? daySlots = _dailySlots[dateKey];
      if (daySlots == null) continue;

      List<String> ranges = [];
      int? startIdx;
      int? endIdx;

      for (int i = 0; i < daySlots.length; i++) {
        bool isTarget = slotMatchesTarget(daySlots[i], target);
        if (isTarget) {
          startIdx ??= i;
          endIdx = i;
        } else {
          if (startIdx != null) {
            ranges.add(_formatRange(startIdx, endIdx!));
            startIdx = null;
            endIdx = null;
          }
        }
      }
      // 处理一天结束时的最后一段
      if (startIdx != null) {
        ranges.add(_formatRange(startIdx, endIdx!));
      }

      if (ranges.isNotEmpty) {
        DateTime? date = _parseDateKey(dateKey);
        if (date != null) {
          String formattedDate =
              "${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}";
          history[formattedDate] = ranges;
        }
      }
    }
    return history;
  }

  DateTime? _parseDateKey(String dateKey) {
    try {
      final parts = dateKey.split('-');
      if (parts.length != 3) return null;
      final year = int.tryParse(parts[0]);
      final month = int.tryParse(parts[1]);
      final day = int.tryParse(parts[2]);
      if (year == null || month == null || day == null) return null;
      return DateTime(year, month, day);
    } catch (_) {
      return null;
    }
  }

  String _formatRange(int startIdx, int endIdx) {
    int startH = startIdx ~/ 6;
    int startM = (startIdx % 6) * 10;
    // endIdx 是闭区间，结束时间是 endIdx + 1 个格子的开始时间
    int endTotalIdx = endIdx + 1;
    int endH = endTotalIdx ~/ 6;
    int endM = (endTotalIdx % 6) * 10;

    String startStr =
        "${startH.toString().padLeft(2, '0')}:${startM.toString().padLeft(2, '0')}";
    String endStr =
        "${endH.toString().padLeft(2, '0')}:${endM.toString().padLeft(2, '0')}";
    // 特殊处理 24:00
    if (endH == 24 && endM == 0) endStr = "24:00";

    return "$startStr~$endStr";
  }

  int _parseTime(String time) {
    if (time.isEmpty) return 0;
    try {
      final parts = time.split(':');
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    } catch (_) {
      return 0;
    }
  }

  // 计算目标在当前周期内的进度
  double calculateTargetProgress(Target target) {
    DateTime now = DateTime.now();
    // 归一化到当天的 00:00:00
    DateTime startDate = DateTime(now.year, now.month, now.day);
    DateTime endDate = startDate.add(const Duration(days: 1));

    // 1. 确定统计的时间范围
    if (target.period == "每周" || target.period == "本周") {
      // 假设周一为一周开始
      startDate = startDate.subtract(Duration(days: startDate.weekday - 1));
      endDate = startDate.add(const Duration(days: 7));
    } else if (target.period == "每月" || target.period == "本月") {
      startDate = DateTime(now.year, now.month, 1);
      endDate = DateTime(now.year, now.month + 1, 1);
    } else if (target.period == "每年" || target.period == "今年") {
      startDate = DateTime(now.year, 1, 1);
      endDate = DateTime(now.year + 1, 1, 1);
    } else if (target.period.startsWith("每") &&
        target.period.endsWith("天") &&
        target.period != "每天") {
      try {
        final match = RegExp(r'每(\d+)天').firstMatch(target.period);
        if (match != null) {
          final periodDays = int.tryParse(match.group(1) ?? '');
          if (periodDays != null && periodDays > 0) {
            final targetIdMs = int.tryParse(target.id);
            if (targetIdMs != null) {
              DateTime createTime =
                  DateTime.fromMillisecondsSinceEpoch(targetIdMs);
              DateTime startOfCreate =
                  DateTime(createTime.year, createTime.month, createTime.day);
              int daysSince = startDate.difference(startOfCreate).inDays;
              if (daysSince >= 0) {
                int cycleIndex = daysSince ~/ periodDays;
                startDate =
                    startOfCreate.add(Duration(days: cycleIndex * periodDays));
                endDate = startDate.add(Duration(days: periodDays));
              }
            }
          }
        }
      } catch (_) {}
    }

    double totalValue = 0.0;
    for (DateTime d = startDate;
        d.isBefore(endDate);
        d = d.add(const Duration(days: 1))) {
      String key = _getDateKey(d);
      if (_dailySlots.containsKey(key)) {
        List<TimeSlot> slots = _dailySlots[key]!;
        if (target.type == TargetType.duration) {
          totalValue +=
              slots.where((s) => slotMatchesTarget(s, target)).length *
                  10.0 /
                  60.0;
        } else if (target.type == TargetType.frequency) {
          bool inBlock = false;
          for (var slot in slots) {
            bool isTarget = slotMatchesTarget(slot, target);
            if (isTarget && !inBlock) {
              totalValue += 1;
              inBlock = true;
            } else if (!isTarget) {
              inBlock = false;
            }
          }
        }
      }
    }
    return totalValue;
  }

  /// 获取目标的每日目标次数
  int getTargetDailyGoal(Target target) {
    if (target.type == TargetType.frequency) {
      return target.frequencyCount;
    }
    return 1;
  }

  /// 获取目标的周目标次数
  int getTargetWeeklyGoal(Target target) {
    final dailyGoal = getTargetDailyGoal(target);
    if (target.period == "每天") return dailyGoal * 7;
    if (target.period == "每周" || target.period == "本周") {
      return target.frequencyCount;
    }
    return dailyGoal * 7;
  }

  /// 获取目标的月目标次数
  int getTargetMonthlyGoal(Target target) {
    final dailyGoal = getTargetDailyGoal(target);
    if (target.period == "每天") return dailyGoal * 30;
    if (target.period == "每月" || target.period == "本月") {
      return target.frequencyCount;
    }
    return dailyGoal * 30;
  }

  /// 获取目标的季度目标次数
  int getTargetQuarterlyGoal(Target target) {
    final dailyGoal = getTargetDailyGoal(target);
    if (target.period == "每天") return dailyGoal * 91;
    return getTargetMonthlyGoal(target) * 3;
  }

  /// 获取目标的年目标次数
  int getTargetYearlyGoal(Target target) {
    final dailyGoal = getTargetDailyGoal(target);
    if (target.period == "每天") return dailyGoal * 365;
    return getTargetMonthlyGoal(target) * 12;
  }

  Map<String, double> getStatistics(DateTime start, DateTime end) {
    final cacheKey = '${_getDateKey(start)}_${_getDateKey(end)}';
    if (_statsCacheKey == cacheKey && _statsCache != null) {
      // 返回不可变包装，防止调用方修改污染缓存
      return Map.unmodifiable(_statsCache!);
    }

    Map<String, double> stats = {};

    // 遍历日期范围内的每一天
    for (int i = 0; i <= end.difference(start).inDays; i++) {
      DateTime date = start.add(Duration(days: i));
      String key = _getDateKey(date);

      if (_dailySlots.containsKey(key)) {
        for (var slot in _dailySlots[key]!) {
          if (slot.recorded && slot.label != null) {
            // 每个格子代表 1/6 小时 (10分钟)
            stats[slot.label!] = (stats[slot.label!] ?? 0) + (1 / 6);
          }
        }
      }
    }

    _statsCacheKey = cacheKey;
    _statsCache = stats;
    return Map.unmodifiable(stats);
  }

  /// 获取按父事件汇总的统计（每个父事件包含自己的时间 + 所有子事件的时间）
  Map<String, double> getParentStatistics(DateTime start, DateTime end) {
    // 先获取详细统计
    final detailStats = getStatistics(start, end);
    Map<String, double> parentStats = {};

    // 建立子事件（含隐藏子事件）到父事件的映射；真正的父事件名集合
    final Map<String, String> childToParent = {};
    final Set<String> parentNames = {};
    for (final cat in _categories) {
      parentNames.add(cat.name);
      for (final sub in cat.subCategories) {
        childToParent[sub] = cat.name;
      }
      for (final sub in cat.hiddenSubCategories) {
        childToParent[sub] = cat.name;
      }
    }

    // 汇总统计
    detailStats.forEach((label, hours) {
      final parentName = childToParent[label];
      if (parentName != null) {
        // 子事件：累加到父事件
        parentStats[parentName] = (parentStats[parentName] ?? 0) + hours;
      } else if (parentNames.contains(label) &&
          label != temporaryCategoryName) {
        // 父事件本身：直接添加（"临时"保留名除外，统一归入聚合项）
        parentStats[label] = (parentStats[label] ?? 0) + hours;
      } else {
        // 临时事件（无归属，含恰好命名为"临时"的标签）：统一归入"临时"聚合项
        parentStats[temporaryCategoryName] =
            (parentStats[temporaryCategoryName] ?? 0) + hours;
      }
    });

    return parentStats;
  }

  /// 收集日期范围内不属于任何分类（父事件/子事件/隐藏子事件）的历史标签，
  /// 即统计视图中应归入"临时"聚合项的临时事件名。
  ///
  /// 不传日期范围时保留全部历史的行为，供临时事件详情使用。
  Set<String> getTemporaryLabels([DateTime? start, DateTime? end]) {
    final known = <String>{};
    for (final cat in _categories) {
      // 保留分类名"临时"本身不计入已知，使恰好命名为"临时"的标签也被识别为临时事件
      if (cat.name == temporaryCategoryName) continue;
      known.add(cat.name);
      known.addAll(cat.subCategories);
      known.addAll(cat.hiddenSubCategories);
    }
    final temps = <String>{};
    if (start == null || end == null) {
      for (final slots in _dailySlots.values) {
        for (final slot in slots) {
          if (slot.recorded &&
              slot.label != null &&
              !known.contains(slot.label)) {
            temps.add(slot.label!);
          }
        }
      }
    } else {
      for (int i = 0; i <= end.difference(start).inDays; i++) {
        final dateKey = _getDateKey(start.add(Duration(days: i)));
        for (final slot in _dailySlots[dateKey] ?? const <TimeSlot>[]) {
          if (slot.recorded &&
              slot.label != null &&
              !known.contains(slot.label)) {
            temps.add(slot.label!);
          }
        }
      }
    }
    return temps;
  }

  /// 获取“全部事件”统计：当前有归属的事件保持独立，无归属历史标签合并为“临时”。
  Map<String, double> getStatisticsWithTemporaryGrouped(
      DateTime start, DateTime end) {
    final stats = Map<String, double>.from(getStatistics(start, end));
    final temporaryLabels = getTemporaryLabels(start, end);
    var temporaryHours = 0.0;

    for (final label in temporaryLabels) {
      temporaryHours += stats.remove(label) ?? 0;
    }
    if (temporaryHours > 0) {
      stats[temporaryCategoryName] = temporaryHours;
    }
    return stats;
  }

  /// 统计每个事件在日期范围内出现的连续块次数（用于词云权重）
  Map<String, int> getEventOccurrenceCounts(DateTime start, DateTime end) {
    final cacheKey = '_occ_${start.toIso8601String()}_${end.toIso8601String()}';
    if (_occurrenceCacheKey == cacheKey && _occurrenceCache != null) {
      // 返回不可变包装，防止调用方修改污染缓存
      return Map.unmodifiable(_occurrenceCache!);
    }

    final counts = <String, int>{};

    for (int i = 0; i <= end.difference(start).inDays; i++) {
      final date = start.add(Duration(days: i));
      final key = _getDateKey(date);
      final daySlots = _dailySlots[key];
      if (daySlots == null || daySlots.isEmpty) continue;

      var j = 0;
      while (j < daySlots.length) {
        final slot = daySlots[j];
        if (!(slot.recorded && slot.label != null && slot.label!.isNotEmpty)) {
          j++;
          continue;
        }

        final label = slot.label!;
        counts[label] = (counts[label] ?? 0) + 1;

        // 跳过同一连续块
        j++;
        while (j < daySlots.length &&
            daySlots[j].recorded &&
            daySlots[j].label == label) {
          j++;
        }
      }
    }

    _occurrenceCacheKey = cacheKey;
    _occurrenceCache = counts;
    return Map.unmodifiable(counts);
  }

  // 在 TimeProvider 类中添加
  Map<String, List<({String range, String label})>> getEventHistory(
      String eventName, int tabIndex) {
    Map<String, List<({String range, String label})>> history = {};

    // 确定起始日期
    DateTime now = DateTime.now();
    DateTime start;
    if (tabIndex == 0) {
      start = DateTime(now.year, now.month, now.day);
    } else if (tabIndex == 1) {
      start = now.subtract(const Duration(days: 7));
    } else if (tabIndex == 2) {
      // 近一月：取上个月的同一天；若该日在上个月不存在（如 3/31 → 2 月
      // 只有 28/29 天），则取上个月最后一天，避免 DateTime 归一化把窗口错位
      final lastMonthLastDay = DateTime(now.year, now.month, 0); // 上个月最后一天
      start = now.day <= lastMonthLastDay.day
          ? DateTime(now.year, now.month - 1, now.day)
          : lastMonthLastDay;
    } else {
      // 全部历史：从最早有数据的日期开始
      if (_dailySlots.isEmpty) {
        start = now;
      } else {
        final keys = _dailySlots.keys.toList()..sort();
        final first = keys.first.split('-');
        final y = int.tryParse(first[0]) ?? now.year;
        final m = int.tryParse(first.length > 1 ? first[1] : '') ?? 1;
        final d = int.tryParse(first.length > 2 ? first[2] : '') ?? 1;
        start = DateTime(y, m, d);
      }
    }

    // 确定有效的 label 集合：如果 eventName 是父分类名，则包含其所有子分类名；
    // 若为"临时"聚合项，则展开为所有临时事件名
    Set<String> validLabels;
    if (eventName == temporaryCategoryName) {
      validLabels = getTemporaryLabels();
    } else {
      validLabels = {eventName};
      for (final cat in _categories) {
        if (cat.name == eventName) {
          validLabels.addAll(cat.subCategories);
          validLabels.addAll(cat.hiddenSubCategories);
          break;
        }
      }
    }

    // 遍历日期
    for (int i = 0; i <= now.difference(start).inDays; i++) {
      DateTime date = now.subtract(Duration(days: i));
      String dateKey = _getDateKey(date);

      if (_dailySlots.containsKey(dateKey)) {
        List<TimeSlot> daySlots = _dailySlots[dateKey]!;
        List<({String range, String label})> ranges = [];

        int j = 0;
        while (j < daySlots.length) {
          if (daySlots[j].recorded &&
              daySlots[j].label != null &&
              validLabels.contains(daySlots[j].label)) {
            final blockLabel = daySlots[j].label!;
            int startIdx = j;
            while (j < daySlots.length &&
                daySlots[j].recorded &&
                daySlots[j].label != null &&
                daySlots[j].label == blockLabel) {
              j++;
            }
            // 转换索引为时间字符串，例如 "08:00 - 08:30"
            String startT =
                "${(startIdx ~/ 6).toString().padLeft(2, '0')}:${(startIdx % 6 * 10).toString().padLeft(2, '0')}";
            String endT =
                "${(j ~/ 6).toString().padLeft(2, '0')}:${(j % 6 * 10).toString().padLeft(2, '0')}";
            ranges.add((range: "$startT - $endT", label: blockLabel));
          } else {
            j++;
          }
        }

        if (ranges.isNotEmpty) {
          history["${date.month}月${date.day}日"] = ranges;
        }
      }
    }
    return history;
  }

  Category? findCategoryById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final cat in _categories) {
      if (cat.id == id) return cat;
    }
    return null;
  }

  /// 可搜索的事件名称：分类、子分类及历史记录中出现过的 label
  List<String> getSearchableLabels() {
    final labels = <String>{};
    for (final cat in _categories) {
      labels.add(cat.name);
      labels.addAll(cat.subCategories);
    }
    for (final daySlots in _dailySlots.values) {
      for (final slot in daySlots) {
        if (slot.recorded && slot.label != null && slot.label!.isNotEmpty) {
          labels.add(slot.label!);
        }
      }
    }
    final list = labels.toList()..sort();
    return list;
  }

  bool _slotMatchesSearchQuery(TimeSlot slot, String queryLower) {
    if (!slot.recorded || slot.label == null) return false;
    if (slot.label!.toLowerCase().contains(queryLower)) return true;
    final cat = findCategoryById(slot.categoryId);
    if (cat != null && cat.name.toLowerCase().contains(queryLower)) {
      return true;
    }
    return false;
  }

  /// 按关键词搜索历史记录，结果按日期倒序
  List<SearchRecordGroup> searchRecords(
    String query, {
    DateTime? startDate,
    DateTime? endDate,
  }) {
    final queryLower = query.trim().toLowerCase();
    if (queryLower.isEmpty) return [];

    final now = DateTime.now();
    final endDay = endDate != null
        ? DateTime(endDate.year, endDate.month, endDate.day)
        : DateTime(now.year, now.month, now.day);
    final startDay = startDate != null
        ? DateTime(startDate.year, startDate.month, startDate.day)
        : DateTime(2020);

    final startKey = _getDateKey(startDay);
    final endKey = _getDateKey(endDay);

    // 只遍历范围内有记录的日期，避免对每一天（含大量空日期）逐日扫描
    final keys = _dailySlots.keys
        .where((k) => k.compareTo(startKey) >= 0 && k.compareTo(endKey) <= 0)
        .toList()
      ..sort((a, b) => b.compareTo(a)); // 按日期倒序

    final groups = <SearchRecordGroup>[];
    for (final dateKey in keys) {
      final daySlots = _dailySlots[dateKey];
      if (daySlots == null) continue;
      final entries = <SearchRecordEntry>[];
      int i = 0;
      while (i < daySlots.length) {
        if (!_slotMatchesSearchQuery(daySlots[i], queryLower)) {
          i++;
          continue;
        }
        final label = daySlots[i].label!;
        final color = daySlots[i].color;
        final startIdx = i;
        // 连续块内 label 相同且首槽已匹配，无需对每个槽位重复匹配查询
        while (i < daySlots.length &&
            daySlots[i].recorded &&
            daySlots[i].label == label) {
          i++;
        }
        entries.add(SearchRecordEntry(
          label: label,
          timeRange: _formatRange(startIdx, i - 1),
          color: color,
          durationMinutes: (i - startIdx) * 10,
        ));
      }
      if (entries.isNotEmpty) {
        groups.add(SearchRecordGroup(
          date: DateTime.parse(dateKey),
          entries: entries,
        ));
      }
    }
    return groups;
  }
}

/// 在后台 isolate 中执行全量时间块 JSON 编码（compute 回调必须是顶层函数）
String _encodeSlotsJson(Map<String, dynamic> slotsJson) =>
    json.encode(slotsJson);
