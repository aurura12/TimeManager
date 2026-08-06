import 'package:flutter/material.dart' hide Category;
import 'package:flutter/foundation.dart' hide Category;
import '../models/time_slot.dart'; // 确保导入了模型
import '../models/category.dart';
import 'dart:convert';
import '../services/google_calendar_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';
import '../models/target.dart';
import '../models/schedule_template.dart';
import '../models/calendar_block.dart';
import '../models/search_result.dart';
import '../services/home_widget_service.dart';
import '../services/diary_local_store.dart';
import '../services/schedule_day_merge.dart';
import '../services/schedule_gitee_service.dart';
import '../services/category_document_merge.dart';
import '../services/category_gitee_service.dart';
import '../models/diary_kind.dart';
import '../models/known_google_users.dart';
import '../services/app_user_identity_store.dart';
import 'target_stats_cache.dart';

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

class TimeProvider with ChangeNotifier {
  static const int backupVersion = 1;
  static const Color calendarImportColor = Color(0xFF78909C);
  Timer? _debounceTimer;
  Future<void>? _ongoingSave;
  int _saveRequestRevision = 0;

  DateTime _currentDate = DateTime.now();
  bool _isSyncing = false; // 添加同步锁标志，防止并发同步导致重复

  /// 本地已改、尚未成功同步到日历的日期（dateKey 列表）
  bool _googleCalendarSyncEnabled = !Platform.isWindows;
  bool get googleCalendarSyncEnabled =>
      !Platform.isWindows && _googleCalendarSyncEnabled;
  bool get isWindows => Platform.isWindows;
  bool _hasSelectedScheduleUser = !Platform.isWindows;
  bool get hasSelectedScheduleUser => _hasSelectedScheduleUser;

  /// 是否正在查看对方日程（合并了远端数据）
  bool _remoteViewEnabled = false;
  bool get isRemoteViewEnabled => _remoteViewEnabled;
  final Map<String, String> _remoteViewBackup = {}; // dateKey → 本地 JSON 快照

  /// 当前日程用户身份，从本地持久化存储加载（与打卡一致）
  DiaryKind get scheduleUser => _scheduleUser;

  String get scheduleUserCode => scheduleUser.code;

  DiaryKind _scheduleUser = DiaryKind.g;
  static const String _scheduleUserKey = 'schedule_user_kind';

  Future<void> setScheduleUser(DiaryKind kind) async {
    if (_scheduleUser == kind && _hasSelectedScheduleUser) return;
    _scheduleUser = kind;
    _hasSelectedScheduleUser = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scheduleUserKey, kind.code);
    await AppUserIdentityStore.saveManualKind(kind);
    notifyListeners();
    // 切换身份后拉取新身份当前日期的日程
    _pullOwnScheduleIfWindows();
    if (Platform.isWindows && _pendingSyncDates.isNotEmpty) {
      unawaited(syncAllSchedulesToGitee());
    }
  }

  Future<void> setGoogleCalendarSyncEnabled(bool enabled) async {
    if (Platform.isWindows) return;
    if (_googleCalendarSyncEnabled == enabled) return;
    _googleCalendarSyncEnabled = enabled;
    if (!enabled) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      if (!_syncStatusController.isClosed) {
        _syncStatusController.add("Google 鏃ュ巻鍚屾宸插叧闂?");
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('google_calendar_sync_enabled', enabled);
    notifyListeners();
    if (enabled) {
      unawaited(_restoreGoogleInBackground());
    }
  }

  final Set<String> _pendingSyncDates = {};
  Set<String> get pendingSyncDates => Set.unmodifiable(_pendingSyncDates);
  bool get hasPendingSync => _pendingSyncDates.isNotEmpty;
  bool get hasPendingSyncForCurrentDate =>
      _pendingSyncDates.contains(_getDateKey(_currentDate));

  // 分类展开状态持久化（以 Category ID 为 key，避免拖动排序时错位）
  Map<String, bool> _categoryExpandStates = {};
  bool _categoryExpandDirty = false; // 展开状态是否已变化，变化时才写盘

  bool getCategoryExpandState(String categoryId) {
    return _categoryExpandStates[categoryId] ?? true; // 默认展开
  }

  void setCategoryExpandState(String categoryId, bool isExpanded) {
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
  bool get isInitialLoadFinished => _isInitialLoadFinished;

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
    _debounceTimer?.cancel();
    _scheduleGiteeTimer?.cancel();
    _categoriesGiteeTimer?.cancel();
    _googleAuthSubscription?.cancel();
    _syncStatusController.close();
    _scheduleGiteeSyncController?.close();
    _targetStatsChangedController.close();
    super.dispose();
  }

  TimeProvider() {
    _googleAuthSubscription =
        GoogleCalendarService.authStateChanges.listen((_) {
      notifyListeners();
      unawaited(pullGoogleCalendarForCurrentDate());
    });
    _init();
  }

  Future<void> _init() async {
    // 先加载本地数据并刷新 UI，避免等待 Google 静默登录阻塞首屏
    try {
      await _loadData();
    } catch (e) {
      debugPrint('初始数据加载失败: $e');
    } finally {
      // 无论加载成败都标记加载已结束，避免依赖此标志的特性（如那年今日弹窗）被静默跳过
      _isInitialLoadFinished = true;
    }
    notifyListeners();
    await _refreshHomeWidget();
    // 从本地持久化存储直接加载用户身份（不联网，瞬间完成）
    await _loadScheduleUserFromStore();
    // 拉取当前身份的分类（事件/子事件）到本地（安卓与 Windows 都执行）
    unawaited(_pullCategoriesFromGitee());
    // Windows 上拉取当前日期自己的日程，补上安卓端推送的数据
    _pullOwnScheduleIfWindows();
    // 后台恢复 Google 日历会话（不阻塞）
    unawaited(GoogleCalendarService.restoreSignIn(background: true));
  }

  Future<void> _loadScheduleUserFromStore() async {
    if (Platform.isWindows) {
      final manualKind = await AppUserIdentityStore.loadManualKind();
      if (manualKind != null) {
        _scheduleUser = manualKind;
        _hasSelectedScheduleUser = true;
      }
      notifyListeners();
      return;
    }
    final identity = await AppUserIdentityStore.load();
    if (identity != null) {
      final nickname = KnownGoogleUsers.nicknameFor(identity.email);
      if (nickname == '乖乖') {
        _scheduleUser = DiaryKind.g;
      } else if (nickname == '晶晶') {
        _scheduleUser = DiaryKind.j;
      }
    }
  }

  Future<void> _restoreGoogleInBackground() async {
    if (!_googleCalendarSyncEnabled) return;
    await GoogleCalendarService.restoreSignIn(background: true);
    if (GoogleCalendarService.isSignedIn) {
      notifyListeners();
      await pullGoogleCalendarForCurrentDate();
    } else if (GoogleCalendarService.needsCalendarReconnect) {
      notifyListeners();
    }
  }

  DateTime get currentDate => _currentDate;

  final Map<String, List<List<TimeSlot>>> _undoStacks = {};
  final int _maxStackSize = 20; // 最大支持撤回 20 步

  List<TimeSlot> get slots {
    String dateKey = _getDateKey(_currentDate);
    return _dailySlots.putIfAbsent(dateKey, () => _generateInitialSlots());
  }

  /// 获取指定日期的时间块列表
  List<TimeSlot>? getSlotsForDate(String dateKey) {
    return _dailySlots[dateKey];
  }

  /// 获取（必要时生成）指定日期的 144 槽位，供双列视图等按日期渲染使用。
  /// 空槽不会被标记为 dirty，不会触发落盘。
  List<TimeSlot> slotsForDate(DateTime date) {
    return _dailySlots.putIfAbsent(_getDateKey(date), () => _generateInitialSlots());
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
    _currentDate = _currentDate.subtract(const Duration(days: 1));
    notifyListeners();
    _refreshHomeWidget();
    pullGoogleCalendarForCurrentDate();
    _pullOwnScheduleIfWindows();
  }

  void nextDay() {
    _currentDate = _currentDate.add(const Duration(days: 1));
    notifyListeners();
    _refreshHomeWidget();
    pullGoogleCalendarForCurrentDate();
    _pullOwnScheduleIfWindows();
  }

  void goToDate(DateTime date) {
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
    if (!Platform.isWindows) return;
    if (!_hasSelectedScheduleUser) return;
    if (_remoteViewEnabled) {
      _pullRemoteViewSchedules();
    } else {
      unawaited(pullScheduleFromGitee());
    }
  }

  /// 远程视图下：对当前三列日期备份本地（仅首次访问的日期）并拉取对方数据。
  /// 远程视图期间切换日期时，由 [_pullOwnScheduleIfWindows] 调用。
  void _pullRemoteViewSchedules() {
    final otherCode = _scheduleUser.code == 'g' ? 'j' : 'g';
    for (final d in _getRemoteViewDates()) {
      _backupAndClearDay(_getDateKey(d));
      unawaited(pullScheduleFromGitee(userCode: otherCode, date: d));
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
    if (_remoteViewEnabled) return; // 远程视图只读，禁止编辑本地数据
    _saveSnapshot();
    List<TimeSlot> currentSlots = slots;
    currentSlots[index].recorded = !currentSlots[index].recorded;
    if (currentSlots[index].recorded) {
      currentSlots[index].modifiedAt = DateTime.now();
    }
    final dateKey = _getDateKey(_currentDate);
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null); // 通知目标统计变化
  }

  void clearAll() {
    if (_remoteViewEnabled) return; // 远程视图只读，禁止编辑本地数据
    _saveSnapshot();
    String dateKey = _getDateKey(_currentDate);
    _dailySlots[dateKey] = _generateInitialSlots();
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    _markPendingSync();
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null); // 通知目标统计变化
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
    _undoStacks.putIfAbsent(key, () => []);

    _cleanupOldUndoStacks();

    // 深度拷贝当前的 slots
    final daySlots = _dailySlots.putIfAbsent(key, () => _generateInitialSlots());
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
            ))
        .toList();

    _undoStacks[key]!.add(snapshot);

    // 如果超过最大步数，移除最早的一条
    if (_undoStacks[key]!.length > _maxStackSize) {
      _undoStacks[key]!.removeAt(0);
    }
  }

  void undo() {
    if (_remoteViewEnabled) return; // 远程视图只读，禁止编辑本地数据
    String dateKey = _getDateKey(_currentDate);
    if (_undoStacks[dateKey] != null && _undoStacks[dateKey]!.isNotEmpty) {
      _dailySlots[dateKey] = _undoStacks[dateKey]!.removeLast();
      _targetStatsCache.invalidateDate(dateKey);
      _markSlotsDirty(dateKey);
      _markPendingSync();
      _saveData();
      notifyListeners();
      _scheduleCalendarSync();
    }
  }

  void assignCategoryToSlots(Set<int> indices, Category category,
      {String? subLabel, DateTime? date}) {
    if (_remoteViewEnabled) return; // 远程视图只读，禁止编辑本地数据
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
    }
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    // 编辑当前日期（含 Windows 双列左列）走完整同步链路；只有编辑其他日期才跳过防抖同步
    if (date == null || dateKey == _getDateKey(_currentDate)) {
      _markPendingSync();
      _scheduleCalendarSync();
    } else {
      // 双列视图编辑非当前日期：只标记待同步，不触发当前日期的防抖同步
      _pendingSyncDates.add(dateKey);
      _syncDirty = true;
    }
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null); // 通知目标统计变化
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
    final c = _scheduleGiteeSyncController;
    if (c != null && !c.isClosed) c.add(message);
  }

  Timer? _scheduleGiteeTimer;
  bool _scheduleGiteeSyncing = false;

  /// 标记当前日期需要同步到 Gitee（带 3 秒防抖）。
  /// [dateKey] 捕获目标日期，避免防抖期间切换日期推错日期。
  void _markScheduleGiteePending([String? dateKey]) {
    _scheduleGiteeTimer?.cancel();
    final target = dateKey ?? _getDateKey(_currentDate);
    _scheduleGiteeTimer = Timer(const Duration(seconds: 3), () {
      syncScheduleToGitee(dateKey: target);
    });
  }

  /// 推送指定日期日程到 Gitee（每人独立文件）
  Future<void> syncScheduleToGitee({String? dateKey}) async {
    if (_remoteViewEnabled) {
      // 远程视图下本地是对方数据，禁止推送覆盖自己的文件
      _addScheduleSyncStatus('远程视图下不推送');
      return;
    }
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return;
    }
    if (_scheduleGiteeSyncing || _allScheduleSyncing || _allSchedulePulling)
      return;
    _scheduleGiteeSyncing = true;
    try {
      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) {
        _addScheduleSyncStatus('未配置同步 Token');
        _syncStatusController.add("未配置同步 Token");
        return;
      }

      final effectiveDateKey = dateKey ?? _getDateKey(_currentDate);
      final slots = _dailySlots[effectiveDateKey];
      if (slots == null) {
        _clearPendingSyncForCurrentDate(effectiveDateKey);
        return;
      }

      if (!slots.any((s) => s.recorded)) {
        _addScheduleSyncStatus('无日程');
        _clearPendingSyncForCurrentDate(effectiveDateKey);
        return;
      }

      _addScheduleSyncStatus('同步中...');
      if (!_syncStatusController.isClosed) {
        _syncStatusController.add("SYNCING");
      }
      final ok = await _pushScheduleDay(effectiveDateKey, slots);
      if (ok) {
        _addScheduleSyncStatus('已同步');
        _clearPendingSyncForCurrentDate(effectiveDateKey);
        if (!_syncStatusController.isClosed) {
          _syncStatusController.add("日程同步成功");
        }
        Future.delayed(const Duration(seconds: 3), () {
          _addScheduleSyncStatus('');
        });
      } else {
        _addScheduleSyncStatus('同步失败');
        if (!_syncStatusController.isClosed) {
          _syncStatusController.add("日程同步失败");
        }
      }
    } catch (e) {
      _addScheduleSyncStatus('同步失败: $e');
      if (!_syncStatusController.isClosed) {
        _syncStatusController.add("日程同步失败: $e");
      }
    } finally {
      _scheduleGiteeSyncing = false;
      if (!_syncStatusController.isClosed) {
        _syncStatusController.add("IDLE");
      }
    }
  }

  /// 推送单个日期日程到 Gitee：先拉取远端 → 槽位级"后写覆盖"合并 → 推送。
  /// 成功后把合并结果写回本地，保证本地与远端一致。
  Future<bool> _pushScheduleDay(String dateKey, List<TimeSlot> slots) async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.isEmpty) return false;

    final localEntries = _serializeRecordedSlots(slots);
    if (localEntries.isEmpty) return true; // 无数据视为成功

    final userLabel = _scheduleUser == DiaryKind.g ? '乖乖' : '晶晶';

    // 1) 拉取远端
    final pullResult = await ScheduleGiteeService.pullSchedule(
      token: token,
      dateKey: dateKey,
      userCode: _scheduleUser.code,
    );
    final remoteContent = pullResult.success ? pullResult.content : null;

    // 2) 合并（后写覆盖：同槽 ts 大者胜，仅一侧有则保留）
    final remote = parseScheduleContent(remoteContent);
    final merged = mergeScheduleSlots(
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

    final result = await ScheduleGiteeService.pushSchedule(
      token: token,
      dateKey: dateKey,
      userCode: _scheduleUser.code,
      content: content,
      commitMessage: commitMessage,
    );
    if (!result.success) return false;

    // 5) 将合并结果写回本地（含远端更新的槽位），保证本地 == 远端
    _applyScheduleEntriesToSlots(slots, merged);
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    await _saveData();
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
    }
    for (final e in entries) {
      final idx = _parseInt(e['i']);
      if (idx == null || idx < 0 || idx >= slots.length) continue;
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
    if (_remoteViewEnabled) {
      _addScheduleSyncStatus('远程视图下不推送');
      return;
    }
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return;
    }
    if (_allScheduleSyncing || _allSchedulePulling) return;
    _allScheduleSyncing = true;
    // 取消可能正在等待的当日自动同步
    _scheduleGiteeTimer?.cancel();
    try {
      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) {
        _addScheduleSyncStatus('未配置同步 Token');
        return;
      }

      // 收集所有有记录的日期
      final dateKeys = <String>[];
      for (final entry in _dailySlots.entries) {
        if (entry.value.any((s) => s.recorded)) {
          dateKeys.add(entry.key);
        }
      }

      if (dateKeys.isEmpty) {
        _addScheduleSyncStatus('无日程');
        return;
      }

      final total = dateKeys.length;
      var done = 0;
      for (final dateKey in dateKeys) {
        final slots = _dailySlots[dateKey]!;
        _addScheduleSyncStatus('同步中 ${done + 1}/$total...');
        final ok = await _pushScheduleDay(dateKey, slots);
        if (ok) done++;
      }

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
    if (_remoteViewEnabled) {
      _addScheduleSyncStatus('远程视图下不拉取');
      return;
    }
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return;
    }
    if (_allSchedulePulling || _allScheduleSyncing) return;
    _allSchedulePulling = true;
    // 取消等待中的当日自动推送，避免与全量拉取并发
    _scheduleGiteeTimer?.cancel();
    try {
      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) {
        _addScheduleSyncStatus('未配置同步 Token');
        return;
      }

      // 1) 列出远端当前用户所有日程文件
      final listResult = await ScheduleGiteeService.listSchedulePathsWithSha(
        token: token,
        userCode: _scheduleUser.code,
      );
      if (!listResult.success) {
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
        _addScheduleSyncStatus('拉取中 ${done + 1}/$total...');
        final ok = await _pullScheduleDayFromGitee(token, dateKey);
        if (ok) done++;
      }

      // 4) 全部完成后统一落盘 + 通知（避免逐日保存）
      if (done > 0) {
        await _saveData();
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

  /// 拉取单日日程并与本地双向合并，返回是否成功。
  Future<bool> _pullScheduleDayFromGitee(String token, String dateKey) async {
    final result = await ScheduleGiteeService.pullSchedule(
      token: token,
      dateKey: dateKey,
      userCode: _scheduleUser.code,
    );
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
    if (_remoteViewEnabled) return;
    // 捕获归属身份，避免随后切换身份导致同步到错误身份的文件
    _categoriesUserCode = _scheduleUser.code;
    _categoriesGiteeTimer?.cancel();
    _categoriesGiteeTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_syncCategoriesToGitee());
    });
  }

  /// 将本地分类同步到 Gitee：拉远端 → 合并 → 推送合并结果 → 写回本地。
  Future<void> _syncCategoriesToGitee() async {
    if (_remoteViewEnabled) return;
    if (!_hasSelectedScheduleUser) return;
    if (_categoriesGiteeSyncing) return;
    _categoriesGiteeSyncing = true;
    try {
      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) return;
      final userCode =
          _categoriesUserCode.isEmpty ? _scheduleUser.code : _categoriesUserCode;

      final pullResult = await CategoryGiteeService.pullCategories(
          token: token, userCode: userCode);
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
    if (_remoteViewEnabled) return;
    if (!_hasSelectedScheduleUser) return;
    if (_categoriesGiteeSyncing) return;
    _categoriesGiteeSyncing = true;
    try {
      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) return;
      final userCode = _scheduleUser.code;
      final pullResult = await CategoryGiteeService.pullCategories(
          token: token, userCode: userCode);
      if (!pullResult.success || pullResult.content == null) return;
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
  Future<bool> pullScheduleFromGitee({String? userCode, DateTime? date}) async {
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return false;
    }
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.isEmpty) {
      _addScheduleSyncStatus('未配置同步 Token');
      return false;
    }

    final dateKey = _getDateKey(date ?? _currentDate);
    final code = userCode ?? _scheduleUser.code;
    try {
      _addScheduleSyncStatus('拉取中...');
      final result = await ScheduleGiteeService.pullSchedule(
        token: token,
        dateKey: dateKey,
        userCode: code,
      );
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

      final remote = parseScheduleContent(result.content);
      final daySlots = _dailySlots.putIfAbsent(dateKey, _generateInitialSlots);
      for (final item in remote.slots) {
        final map = item;
        final idx = _parseInt(map['i']);
        if (idx == null) continue;
        if (idx >= 0 && idx < daySlots.length) {
          daySlots[idx].recorded = true;
          daySlots[idx].label = map['l'] as String?;
          daySlots[idx].categoryId = map['cid'] as String?;
          if (map['c'] != null) {
            final colorVal = _parseInt(map['c']);
            if (colorVal != null) daySlots[idx].color = Color(colorVal);
          }
          final ts = _parseInt(map['ts']);
          if (ts != null && ts > 0) {
            daySlots[idx].modifiedAt = DateTime.fromMillisecondsSinceEpoch(ts);
          }
        }
      }
      _markAllSlotsDirty();
      if (!_remoteViewEnabled) _saveData();
      notifyListeners();
      _addScheduleSyncStatus('已同步');
      Future.delayed(const Duration(seconds: 3), () {
        _addScheduleSyncStatus('');
      });
      return true;
    } catch (e) {
      _addScheduleSyncStatus('拉取失败: $e');
      return false;
    }
  }

  /// 切换查看对方日程。打开时显示纯远端数据；关闭时恢复本地数据。
  /// Windows 三列视图下覆盖选中日及前后各一天，安卓仅覆盖选中日。
  Future<void> toggleRemoteScheduleView() async {
    if (!_hasSelectedScheduleUser) {
      _addScheduleSyncStatus('请先选择身份');
      return;
    }
    if (_remoteViewEnabled) {
      // 关闭：按备份过的日期逐一恢复本地数据
      final backupKeys = _remoteViewBackup.keys.toList();
      for (final dk in backupKeys) {
        final slots = _dailySlots[dk] ?? _generateInitialSlots();
        final backup = parseScheduleContent(_remoteViewBackup.remove(dk));
        _clearDaySlots(slots, clearModifiedAt: true);
        for (final map in backup.slots) {
          final idx = _parseInt(map['i']);
          if (idx == null) continue;
          if (idx >= 0 && idx < slots.length) {
            slots[idx].recorded = true;
            slots[idx].label = map['l'] as String?;
            slots[idx].categoryId = map['cid'] as String?;
            if (map['c'] != null) {
              final colorVal = _parseInt(map['c']);
              if (colorVal != null) slots[idx].color = Color(colorVal);
            }
            if (map['fc'] == true) slots[idx].isFromCalendar = true;
            if (map['eid'] != null)
              slots[idx].calendarEventId = map['eid'] as String?;
            final ts = _parseInt(map['ts']);
            if (ts != null && ts > 0) {
              slots[idx].modifiedAt = DateTime.fromMillisecondsSinceEpoch(ts);
            }
          }
        }
      }
      if (backupKeys.isNotEmpty) {
        _markAllSlotsDirty();
        _saveData();
      }
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
      await _saveData();

      // 3) 备份并清空（Windows 三天 / 安卓一天）
      final dates = _getRemoteViewDates();
      for (final d in dates) {
        _backupAndClearDay(_getDateKey(d));
      }
      _markAllSlotsDirty();

      // 5) 提前标记远程视图状态，这样 pullScheduleFromGitee 内部的
      //    `if (!_remoteViewEnabled) _saveData()` 不会错误地保存到本地缓存
      _remoteViewEnabled = true;

      // 6) 拉取对方的文件（独立文件，无需过滤）；Windows 逐日拉取三天
      final otherCode = _scheduleUser.code == 'g' ? 'j' : 'g';
      for (final d in dates) {
        await pullScheduleFromGitee(userCode: otherCode, date: d);
      }
      // 拉取后不保存到本地持久化——由提前设置的 _remoteViewEnabled 保证
    }
    notifyListeners();
  }

  /// 远程视图覆盖的日期：Windows 三列（选中日 ±1 天），安卓仅选中日。
  List<DateTime> _getRemoteViewDates() {
    if (!Platform.isWindows) return [_currentDate];
    return [
      _currentDate.subtract(const Duration(days: 1)),
      _currentDate,
      _currentDate.add(const Duration(days: 1)),
    ];
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
      if (clearModifiedAt) s.modifiedAt = null;
    }
  }

  /// 本地与云端日历不一致时标记（与是否已登录无关）
  void _markPendingSync() {
    _pendingSyncDates.add(_getDateKey(_currentDate));
    _syncDirty = true;
    _markScheduleGiteePending();
  }

  void _clearPendingSyncForCurrentDate([String? dateKey]) {
    final key = dateKey ?? _getDateKey(_currentDate);
    if (_pendingSyncDates.remove(key)) {
      notifyListeners();
      _saveData();
    }
  }

  /// 应用切到后台：取消防抖计时、立即把本地数据与待同步标记写入磁盘
  Future<void> onAppBackgrounded() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _saveData();
  }

  /// 统一同步：始终同步到 Gitee，若开启 Google 日历同步则同时同步 Google。
  Future<void> syncAll() async {
    // 先同步日程到 Gitee
    await syncScheduleToGitee();
    // 若开启了 Google 日历同步则同步日历
    if (_googleCalendarSyncEnabled) {
      await synchronizeCalendar();
    }
  }

  // 合并后的同步方法
  // delay: true 表示自动同步（带防抖），false 表示手动同步（立即执行）
  Future<void> synchronizeCalendar({bool delay = false}) async {
    if (Platform.isWindows || !_googleCalendarSyncEnabled) {
      if (!delay) {
        _syncStatusController.add("Google 鏃ュ巻鍚屾宸插叧闂?");
      }
      return;
    }
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    Future<void> executeSync() async {
      if (_isSyncing) return;

      if (!GoogleCalendarService.isSignedIn) {
        if (!delay) {
          final msg = GoogleCalendarService.needsCalendarReconnect
              ? '日历未连接，请在设置中重新连接'
              : '未登录 Google 账号，无法同步';
          _syncStatusController.add(msg);
        }
        return;
      }

      _isSyncing = true;
      try {
        _syncStatusController.add("开始同步");
        if (delay) await Future.delayed(const Duration(milliseconds: 500));

        if (!_syncStatusController.isClosed) {
          _syncStatusController.add("SYNCING");
        }

        bool pullOk =
            await pullGoogleCalendarForDate(_currentDate, notify: false);
        final success =
            await GoogleCalendarService.syncSlotsToGoogle(slots, _currentDate);

        if (success) {
          _clearPendingSyncForCurrentDate();
          if (!delay) {
            if (!pullOk) {
              _syncStatusController.add("同步成功（日历拉取失败）");
            } else {
              _syncStatusController.add("同步成功");
            }
          }
        } else if (!delay) {
          if (!pullOk) {
            _syncStatusController.add("从 Google 日历拉取失败");
          } else {
            _syncStatusController.add("同步失败，请稍后重试");
          }
        }

        // 延迟重置状态
        Future.delayed(const Duration(seconds: 3), () {
          if (!_syncStatusController.isClosed) {
            _syncStatusController.add("IDLE");
          }
        });
      } finally {
        _isSyncing = false;
      }
    }

    if (delay) {
      _debounceTimer = Timer(const Duration(seconds: 3), executeSync);
    } else {
      await executeSync();
    }
  }

  /// 手动同步所有待同步日期（用于个人中心“待同步”按钮）
  Future<void> synchronizeAllPendingCalendars() async {
    if (!_googleCalendarSyncEnabled) {
      _syncStatusController.add("Google 鏃ュ巻鍚屾宸插叧闂?");
      return;
    }
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    // 可能与自动同步并发：等待当前同步完成，避免手动点击被无声忽略
    var waitedMs = 0;
    while (_isSyncing && waitedMs < 10000) {
      await Future.delayed(const Duration(milliseconds: 200));
      waitedMs += 200;
    }
    if (_isSyncing) {
      _syncStatusController.add("同步进行中，请稍后重试");
      return;
    }

    if (!GoogleCalendarService.isSignedIn) {
      _syncStatusController.add("未登录 Google 账号，无法同步");
      return;
    }

    final pendingKeys = _pendingSyncDates.toList();
    if (pendingKeys.isEmpty) {
      await synchronizeCalendar();
      return;
    }

    _isSyncing = true;
    try {
      _syncStatusController.add("SYNCING");

      var allSuccess = true;
      for (final rawKey in pendingKeys) {
        final dateKey = rawKey.trim();
        final parts = dateKey.split('-');
        if (parts.length != 3) continue;

        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);
        if (year == null || month == null || day == null) {
          // 异常 key 直接清掉，避免状态永远卡在“待同步”
          _pendingSyncDates.remove(rawKey);
          allSuccess = false;
          continue;
        }

        final date = DateTime(year, month, day);
        final slotsForDay = _dailySlots[dateKey] ?? _generateInitialSlots();
        final pullOk = await pullGoogleCalendarForDate(date, notify: false);
        final pushed =
            await GoogleCalendarService.syncSlotsToGoogle(slotsForDay, date);

        if (pushed) {
          _pendingSyncDates.remove(dateKey);
        } else {
          allSuccess = false;
        }

        if (!pullOk) {
          allSuccess = false;
        }
      }

      await _saveData();
      notifyListeners();
      if (_pendingSyncDates.isEmpty && allSuccess) {
        _syncStatusController.add("同步成功");
      } else {
        _syncStatusController.add("部分同步失败（剩余${_pendingSyncDates.length}天）");
      }
    } finally {
      _isSyncing = false;
      Future.delayed(const Duration(seconds: 3), () {
        if (!_syncStatusController.isClosed) {
          _syncStatusController.add("IDLE");
        }
      });
    }
  }

  // 移除指定时间块的事件
  void removeEventFromSlot(int index, {DateTime? date}) {
    if (_remoteViewEnabled) return; // 远程视图只读，禁止编辑本地数据
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
          _clearSlotAt(daySlots, index);
          _markSlotsDirty(dateKey);
          _targetStatsCache.invalidateDate(dateKey);
          // 编辑当前日期（含 Windows 双列左列）走完整同步链路；只有编辑其他日期才跳过防抖同步
          if (date == null || dateKey == _getDateKey(_currentDate)) {
            _markPendingSync();
            _scheduleCalendarSync();
          } else {
            // 双列视图编辑非当前日期：只标记待同步，不触发当前日期的防抖同步
            _pendingSyncDates.add(dateKey);
            _syncDirty = true;
          }
          _saveData();
          notifyListeners();
          _targetStatsChangedController.add(null); // 通知目标统计变化
        }
      }
    }
  }

  void _clearSlotAt(List<TimeSlot> daySlots, int index) {
    daySlots[index].recorded = false;
    daySlots[index].label = null;
    daySlots[index].categoryId = null;
    daySlots[index].color = null;
    daySlots[index].isFromCalendar = false;
    daySlots[index].calendarEventId = null;
  }

  Future<void> _dismissCalendarImportAt(int index, {DateTime? date}) async {
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

    final rangeStart = _slotIndexToDateTime(start);
    final rangeEnd = _slotIndexToDateTime(end);
    var eventId = daySlots[index].calendarEventId;
    eventId ??= await _resolveGoogleEventId(label, rangeStart, rangeEnd);

    for (int i = 0; i < daySlots.length; i++) {
      final sameEvent = eventId != null &&
          eventId.isNotEmpty &&
          daySlots[i].calendarEventId == eventId;
      final inRange = i >= start &&
          i < end &&
          daySlots[i].isFromCalendar &&
          daySlots[i].label == label;
      if (sameEvent || inRange) {
        _clearSlotAt(daySlots, i);
      }
    }

    if (eventId != null && eventId.isNotEmpty) {
      final deleted = await GoogleCalendarService.deleteExternalEvent(eventId);
      if (!deleted) {
        _ignoredCalendarImports.putIfAbsent(dateKey, () => {}).add(eventId);
        if (!_syncStatusController.isClosed) {
          _syncStatusController.add("删除 Google 日历事件失败");
        }
      }
    } else {
      _ignoredCalendarImports.putIfAbsent(dateKey, () => {}).add(
            _calendarBlockFingerprint(label, rangeStart, rangeEnd),
          );
    }

    _markSlotsDirty(dateKey); // 标记当前日期为脏
    _calendarDirty = true; // 忽略列表也变了
    _targetStatsCache.invalidateDate(dateKey); // 失效该日期的缓存
    await _saveData();
    notifyListeners();
  }

  Future<String?> _resolveGoogleEventId(
      String title, DateTime rangeStart, DateTime rangeEnd) async {
    final blocks =
        await GoogleCalendarService.fetchExternalEvents(_currentDate);
    if (blocks == null) return null;

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

  DateTime _slotIndexToDateTime(int index) {
    final d = _currentDate;
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
      if (!oldByIndex.containsKey(idx)) {
        addedEntries.add(newByIndex[idx]!);
      } else {
        final oldLabel = oldByIndex[idx]!['l']?.toString() ?? '';
        final newLabel = newByIndex[idx]!['l']?.toString() ?? '';
        if (oldLabel != newLabel) {
          modifiedEntries.add(newByIndex[idx]!);
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
      // 无变化：列出当前所有日程
      final allEvents = _groupConsecutiveSlots(newEntries);
      final lines = allEvents.take(5).map(formatEvent).toList();
      final suffix = allEvents.length > 5 ? ' 等${allEvents.length}条' : '';
      return '日程($userLabel): $dateKey\n${lines.join('\n')}$suffix';
    }

    return '日程($userLabel): $dateKey\n${parts.join('\n')}';
  }

  // --- Google 日历下拉 ---

  Future<void> pullGoogleCalendarForCurrentDate() async {
    if (Platform.isWindows || !_googleCalendarSyncEnabled) return;
    await pullGoogleCalendarForDate(_currentDate);
  }

  /// 从 Google 拉取外部会议并合并到指定日期；未登录 Google 时返回 false
  Future<bool> pullGoogleCalendarForDate(DateTime date,
      {bool notify = true}) async {
    if (Platform.isWindows || !_googleCalendarSyncEnabled) return false;
    if (!GoogleCalendarService.isSignedIn) return false;

    final blocks = await GoogleCalendarService.fetchExternalEvents(date);
    if (blocks == null) return false;
    final dateKey = _getDateKey(date);
    _mergeCalendarBlocks(dateKey, blocks, date);
    _markSlotsDirty(dateKey);
    _targetStatsCache.invalidateDate(dateKey); // 失效该日期的缓存
    await _saveData();
    if (notify) notifyListeners();
    return true;
  }

  void _mergeCalendarBlocks(
      String dateKey, List<CalendarBlock> blocks, DateTime day) {
    final daySlots =
        _dailySlots.putIfAbsent(dateKey, () => _generateInitialSlots());

    for (int i = 0; i < daySlots.length; i++) {
      if (daySlots[i].isFromCalendar) {
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
      }
    }
  }

  List<int> _timeRangeToSlotIndices(
      DateTime start, DateTime end, DateTime day) {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    var s = start.isBefore(dayStart) ? dayStart : start;
    var e = end.isAfter(dayEnd) ? dayEnd : end;
    if (!e.isAfter(s)) return [];

    final startIndex = s.hour * 6 + s.minute ~/ 10;
    final endIndex = _endSlotIndexExclusive(e);
    if (endIndex <= startIndex) return [];

    return List.generate(endIndex - startIndex, (i) => startIndex + i);
  }

  int _endSlotIndexExclusive(DateTime end) {
    if (end.minute % 10 == 0 && end.second == 0 && end.millisecond == 0) {
      return end.hour * 6 + end.minute ~/ 10;
    }
    return end.hour * 6 + (end.minute + 9) ~/ 10;
  }

  // --- 日程模板 ---

  List<Map<String, dynamic>> _serializeRecordedSlots(List<TimeSlot> slotList,
      {bool excludeCalendar = false}) {
    final recorded = <Map<String, dynamic>>[];
    for (int i = 0; i < slotList.length; i++) {
      if (!slotList[i].recorded) continue;
      if (excludeCalendar && slotList[i].isFromCalendar) continue;
      final entry = <String, dynamic>{
        'i': i,
        'l': slotList[i].label,
        'c': slotList[i].color?.toARGB32(),
      };
      if (slotList[i].modifiedAt != null) {
        entry['ts'] = slotList[i].modifiedAt!.millisecondsSinceEpoch;
      }
      if (slotList[i].categoryId != null &&
          slotList[i].categoryId!.isNotEmpty) {
        entry['cid'] = slotList[i].categoryId;
      }
      if (slotList[i].isFromCalendar) {
        entry['fc'] = true;
      }
      if (slotList[i].calendarEventId != null) {
        entry['eid'] = slotList[i].calendarEventId;
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
    if (_remoteViewEnabled) return; // 远程视图只读，禁止编辑本地数据
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
    _targetStatsChangedController.add(null); // 通知目标统计变化
    _scheduleCalendarSync();
  }

  void renameTemplate(String id, String newName) {
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
    _templates.removeWhere((t) => t.id == id);
    _markTemplatesChanged(); // 标记模板为脏
    _saveData();
    notifyListeners();
  }

  // --- 分类管理方法 (从 HomeScreen 移入) ---

  void addCategory(Category category) {
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

    _categories[index] = updated.copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch);
    _markCategoriesChanged();
    _markCategoriesGiteePending();
    _invalidateLabelCategoryIdCache(); // 清除缓存
    _saveData();
    notifyListeners();
  }

  void hideSubCategory(int catIndex, String subCategory) {
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
    _targetStatsChangedController.add(null); // 通知目标统计变化
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

  Future<void> _saveData() async {
    final previous = _ongoingSave;
    final requestRevision = ++_saveRequestRevision;
    // 串行化保存：等待上一个保存完成后再启动本次，
    // 避免并发读写导致整包写回时互相覆盖丢数据。
    final save = (previous ?? Future<void>.value())
        .catchError((_) {}) // 上一个保存失败不阻断本次
        .then((_) => _saveDataImpl(requestRevision));
    _ongoingSave = save;
    try {
      await save;
    } finally {
      if (_ongoingSave == save) _ongoingSave = null;
    }
  }

  Future<void> _saveDataImpl(int requestRevision) async {
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

    // 1. 保存分类（仅在变化时）
    final categoriesDirtyAtStart = _categoriesDirty;
    if (categoriesDirtyAtStart) {
      List<String> catList = _categories.map((c) => json.encode(c.toJson())).toList();
      await prefs.setStringList('categories', catList);
      // 分类删除墓碑（id → 删除时间戳）与文档时间戳随分类一并持久化
      await prefs.setString(
          'deleted_categories', json.encode(_deletedCategories));
      await prefs.setInt('categories_doc_updated_at', _categoriesDocUpdatedAt);
      if (_saveRequestRevision == requestRevision) {
        _categoriesDirty = false;
      }
    }

    // 2. 保存目标（仅在变化时）
    final targetsDirtyAtStart = _targetsDirty;
    if (targetsDirtyAtStart) {
      List<String> targetList =
          _targets.map((t) => json.encode(t.toJson())).toList();
      await prefs.setStringList('targets', targetList);
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
      await prefs.setString('daily_slots', encoded);
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
      await prefs.setString('daily_slots', json.encode(slotsJson));
      slotsChanged = true;
      if (_saveRequestRevision == requestRevision) {
        _slotsDirty.removeAll(dirtyDatesAtStart);
      }
    }

    // 4. 日程模板（仅在变化时）
    final templatesDirtyAtStart = _templatesDirty;
    if (templatesDirtyAtStart) {
      await prefs.setString(
        'schedule_templates',
        json.encode(_templates.map((t) => t.toJson()).toList()),
      );
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
      await prefs.setString(
          'ignored_calendar_imports', json.encode(ignoredJson));
      if (_saveRequestRevision == requestRevision) {
        _calendarDirty = false;
      }
    }

    // 6. 待同步日期（仅在变化时）
    final syncDirtyAtStart = _syncDirty;
    if (syncDirtyAtStart) {
      await prefs.setStringList(
          'pending_sync_dates', _pendingSyncDates.toList());
      if (_saveRequestRevision == requestRevision) {
        _syncDirty = false;
      }
    }

    // 7. 分类展开状态（仅变化时写，体积小）
    final expandChanged = _categoryExpandDirty;
    if (expandChanged) {
      await prefs.setString(
          'category_expand_states', json.encode(_categoryExpandStates));
      if (_saveRequestRevision == requestRevision) {
        _categoryExpandDirty = false;
      }
    }

    // 小组件只在 slots 或展开状态实际变化时刷新，
    // 避免每次保存（含无变化调用）都走平台通道
    if (slotsChanged || expandChanged) {
      await _refreshHomeWidget();
    }
  }

  Future<void> _refreshHomeWidget() async {
    // 桌面小组件仅 Android 支持，Windows 无实现，直接跳过避免 MissingPluginException
    if (Platform.isWindows) return;
    try {
      await HomeWidgetService.updateFromDay(
        slots: slots,
        date: _currentDate,
        pendingSync: hasPendingSyncForCurrentDate,
      );
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
      'pendingSyncDates': _pendingSyncDates.toList(),
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
    await _saveData();
    notifyListeners();
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
    if (!parsedCategories.any((c) => c.name == '临时')) {
      parsedCategories.add(Category(
        name: '临时',
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
    _pendingSyncDates
      ..clear()
      ..addAll(parsedPending);
  }

  void _ensureTempCategory() {
    if (!_categories.any((c) => c.name == '临时')) {
      _categories.add(Category(
        name: '临时',
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
      Category(name: '临时', color: const Color(0xFF9E9E9E), updatedAt: nowMs),
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
        }
      }
      target[dateKey] = daySlots;
    });
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

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
    _pendingSyncDates
      ..clear()
      ..addAll((prefs.getStringList('pending_sync_dates') ?? [])
          .map(_normalizeDateKey));
    _googleCalendarSyncEnabled = Platform.isWindows
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
    _targetStatsChangedController.add(null);
    _saveData();
    notifyListeners();
  }

  void reorderCategories(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
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
    _targetStatsChangedController.add(null);
  }

  void addTarget(Target target) {
    _targets.add(target);
    _targetsDirty = true;
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null); // 通知目标统计变化
  }

  void updateTarget(Target newTarget) {
    int index = _targets.indexWhere((t) => t.id == newTarget.id);
    if (index != -1) {
      _targets[index] = newTarget;
      _targetsDirty = true;
      _saveData();
      notifyListeners();
      _targetStatsChangedController.add(null); // 通知目标统计变化
    }
  }

  void deleteTarget(Target target) {
    _targets.remove(target);
    _targetsDirty = true;
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null); // 通知目标统计变化
  }

  void reorderTargets(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
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
    if (target.period == "每周" || target.period == "本周")
      return target.frequencyCount;
    return dailyGoal * 7;
  }

  /// 获取目标的月目标次数
  int getTargetMonthlyGoal(Target target) {
    final dailyGoal = getTargetDailyGoal(target);
    if (target.period == "每天") return dailyGoal * 30;
    if (target.period == "每月" || target.period == "本月")
      return target.frequencyCount;
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

    // 建立子事件到父事件的映射
    final Map<String, String> childToParent = {};
    for (final cat in _categories) {
      for (final sub in cat.subCategories) {
        childToParent[sub] = cat.name;
      }
    }

    // 汇总统计
    detailStats.forEach((label, hours) {
      final parentName = childToParent[label];
      if (parentName != null) {
        // 子事件：累加到父事件
        parentStats[parentName] = (parentStats[parentName] ?? 0) + hours;
      } else {
        // 父事件或独立事件：直接添加
        parentStats[label] = (parentStats[label] ?? 0) + hours;
      }
    });

    return parentStats;
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

    // 确定有效的 label 集合：如果 eventName 是父分类名，则包含其所有子分类名
    Set<String> validLabels = {eventName};
    for (final cat in _categories) {
      if (cat.name == eventName) {
        validLabels.addAll(cat.subCategories);
        validLabels.addAll(cat.hiddenSubCategories);
        break;
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
                validLabels.contains(daySlots[j].label)) {
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
