import 'package:flutter/material.dart';
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
import '../services/home_widget_service.dart';
import '../services/diary_local_store.dart';
import '../services/schedule_gitee_service.dart';
import '../models/diary_kind.dart';
import '../models/known_google_users.dart';
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

  DateTime _currentDate = DateTime.now();
  bool _isSyncing = false; // 添加同步锁标志，防止并发同步导致重复

  /// 本地已改、尚未成功同步到日历的日期（dateKey 列表）
  bool _googleCalendarSyncEnabled = true;
  bool get googleCalendarSyncEnabled => _googleCalendarSyncEnabled;

  /// 是否正在查看对方日程（合并了远端数据）
  bool _remoteViewEnabled = false;
  bool get isRemoteViewEnabled => _remoteViewEnabled;
  final Map<String, String> _remoteViewBackup = {}; // dateKey → 本地 JSON 快照

  /// 当前日程用户身份，从 Google 账号自动识别（乖乖=g, 晶晶=j），未登录默认 g
  DiaryKind get scheduleUser {
    final email = GoogleCalendarService.sessionUser?.email;
    if (email != null) {
      final nickname = KnownGoogleUsers.nicknameFor(email);
      if (nickname == '乖乖') return DiaryKind.g;
      if (nickname == '晶晶') return DiaryKind.j;
    }
    // fallback 到本地存储的用户设置
    return _scheduleUser;
  }

  String get scheduleUserCode => scheduleUser.code;

  DiaryKind _scheduleUser = DiaryKind.g;
  static const String _scheduleUserKey = 'schedule_user_kind';

  Future<void> setScheduleUser(DiaryKind kind) async {
    if (_scheduleUser == kind) return;
    _scheduleUser = kind;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scheduleUserKey, kind.code);
    notifyListeners();
  }

  Future<void> setGoogleCalendarSyncEnabled(bool enabled) async {
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

  bool getCategoryExpandState(String categoryId) {
    return _categoryExpandStates[categoryId] ?? true; // 默认展开
  }

  void setCategoryExpandState(String categoryId, bool isExpanded) {
    _categoryExpandStates[categoryId] = isExpanded;
    notifyListeners();
    _saveData();
  }

  // 存储模型对象 Map
  final Map<String, List<TimeSlot>> _dailySlots = {};

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
  bool _targetsDirty = false;
  final Set<String> _slotsDirty = {};  // 变化的日期 key
  bool _allSlotsDirty = false;  // 全量脏标记（用于 _propagateLabelRename 等场景）
  bool _templatesDirty = false;
  bool _calendarDirty = false;
  bool _syncDirty = false;

  // --- 目标统计缓存 ---
  final TargetStatsCache _targetStatsCache = TargetStatsCache();
  TargetStatsCache get targetStatsCache => _targetStatsCache;

  // --- 统计缓存 ---
  String? _statsCacheKey;
  Map<String, double>? _statsCache;

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
    await _loadData();
    notifyListeners();
    await _refreshHomeWidget();
    // 无论如何都恢复 Google 身份识别（仅读本地缓存，不联网），
    // 日程和打卡需要知道当前用户是谁（乖乖/晶晶）
    unawaited(GoogleCalendarService.restoreSignIn(background: true));
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

  // 生成一天 144 个初始槽位对象
  List<TimeSlot> _generateInitialSlots() {
    return List.generate(144, (index) {
      int h = index ~/ 6;
      int m10 = index % 6;
      return TimeSlot(hour: h, minute10: m10, recorded: false);
    });
  }

  String _getDateKey(DateTime date) {
    return "${date.year}-${date.month}-${date.day}";
  }

  void previousDay() {
    _currentDate = _currentDate.subtract(const Duration(days: 1));
    notifyListeners();
    _refreshHomeWidget();
    pullGoogleCalendarForCurrentDate();
  }

  void nextDay() {
    _currentDate = _currentDate.add(const Duration(days: 1));
    notifyListeners();
    _refreshHomeWidget();
    pullGoogleCalendarForCurrentDate();
  }

  void goToDate(DateTime date) {
    _currentDate = DateTime(date.year, date.month, date.day);
    notifyListeners();
    _refreshHomeWidget();
    pullGoogleCalendarForCurrentDate();
  }

  void toggleSlot(int index) {
    _saveSnapshot();
    List<TimeSlot> currentSlots = slots;
    currentSlots[index].recorded = !currentSlots[index].recorded;
    final dateKey = _getDateKey(_currentDate);
    _slotsDirty.add(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null);  // 通知目标统计变化
  }

  void clearAll() {
    _saveSnapshot();
    String dateKey = _getDateKey(_currentDate);
    _dailySlots[dateKey] = _generateInitialSlots();
    _slotsDirty.add(dateKey);
    _targetStatsCache.invalidateDate(dateKey);
    _markPendingSync();
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null);  // 通知目标统计变化
    _scheduleCalendarSync();
  }

  void _saveSnapshot() {
    String dateKey = _getDateKey(_currentDate);
    _undoStacks.putIfAbsent(dateKey, () => []);

    // 深度拷贝当前的 slots
    List<TimeSlot> snapshot = slots
        .map((s) => TimeSlot(
              hour: s.hour,
              minute10: s.minute10,
              recorded: s.recorded,
              label: s.label,
              categoryId: s.categoryId,
              color: s.color,
              isFromCalendar: s.isFromCalendar,
              calendarEventId: s.calendarEventId,
            ))
        .toList();

    _undoStacks[dateKey]!.add(snapshot);

    // 如果超过最大步数，移除最早的一条
    if (_undoStacks[dateKey]!.length > _maxStackSize) {
      _undoStacks[dateKey]!.removeAt(0);
    }
  }

  void undo() {
    String dateKey = _getDateKey(_currentDate);
    if (_undoStacks[dateKey] != null && _undoStacks[dateKey]!.isNotEmpty) {
      _dailySlots[dateKey] = _undoStacks[dateKey]!.removeLast();
      _markPendingSync();
      _saveData();
      notifyListeners();
      _scheduleCalendarSync();
    }
  }

  void assignCategoryToSlots(Set<int> indices, Category category,
      {String? subLabel}) {
    if (indices.isEmpty) return;

    _saveSnapshot();

    final label = subLabel ?? category.name;
    for (var index in indices) {
      slots[index].recorded = true;
      slots[index].label = label;
      slots[index].categoryId = category.id;
      slots[index].color = category.color;
      slots[index].isFromCalendar = false;
      slots[index].calendarEventId = null;
    }
    _slotsDirty.add(_getDateKey(_currentDate));
    _targetStatsCache.invalidateDate(_getDateKey(_currentDate));
    _markPendingSync();
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null);  // 通知目标统计变化
    _scheduleCalendarSync();
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

  Timer? _scheduleGiteeTimer;
  bool _scheduleGiteeSyncing = false;

  /// 标记当前日期需要同步到 Gitee（带 5 秒防抖）
  void _markScheduleGiteePending() {
    _scheduleGiteeTimer?.cancel();
    _scheduleGiteeTimer = Timer(const Duration(seconds: 5), () {
      syncScheduleToGitee();
    });
  }

  /// 推送当前日期日程到 Gitee（每人独立文件，无需合并）
  Future<void> syncScheduleToGitee() async {
    if (_scheduleGiteeSyncing || _allScheduleSyncing) return;
    _scheduleGiteeSyncing = true;
    try {
      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) {
        _scheduleGiteeSyncController?.add('未配置同步 Token');
        return;
      }

      final dateKey = _getDateKey(_currentDate);
      final slots = _dailySlots[dateKey];
      if (slots == null) return;

      if (!slots.any((s) => s.recorded)) {
        _scheduleGiteeSyncController?.add('无日程');
        return;
      }

      _scheduleGiteeSyncController?.add('同步中...');
      final ok = await _pushScheduleDay(dateKey, slots);
      if (ok) {
        _scheduleGiteeSyncController?.add('已同步');
        _clearPendingSyncForCurrentDate();
        Future.delayed(const Duration(seconds: 3), () {
          _scheduleGiteeSyncController?.add('');
        });
      } else {
        _scheduleGiteeSyncController?.add('同步失败');
      }
    } catch (e) {
      _scheduleGiteeSyncController?.add('同步失败: $e');
    } finally {
      _scheduleGiteeSyncing = false;
    }
  }

  /// 提取单个日期推送逻辑，供全量同步复用
  Future<bool> _pushScheduleDay(String dateKey, List<TimeSlot> slots) async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.isEmpty) return false;

    final recorded = _serializeRecordedSlots(slots);
    if (recorded.isEmpty) return true; // 无数据视为成功

    final content = json.encode(recorded);
    final result = await ScheduleGiteeService.pushSchedule(
      token: token,
      dateKey: dateKey,
      userCode: _scheduleUser.code,
      content: content,
      commitMessage: '日程: $dateKey',
    );
    return result.success;
  }

  bool _allScheduleSyncing = false;

  /// 全量同步所有日期的日程到 Gitee
  Future<void> syncAllSchedulesToGitee() async {
    if (_allScheduleSyncing) return;
    _allScheduleSyncing = true;
    // 取消可能正在等待的当日自动同步
    _scheduleGiteeTimer?.cancel();
    try {
      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) {
        _scheduleGiteeSyncController?.add('未配置同步 Token');
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
        _scheduleGiteeSyncController?.add('无日程');
        return;
      }

      final total = dateKeys.length;
      var done = 0;
      for (final dateKey in dateKeys) {
        final slots = _dailySlots[dateKey]!;
        _scheduleGiteeSyncController?.add('同步中 ${done + 1}/$total...');
        final ok = await _pushScheduleDay(dateKey, slots);
        if (ok) done++;
      }

      if (done == total) {
        _scheduleGiteeSyncController?.add('全部同步完成 ($total 天)');
      } else {
        _scheduleGiteeSyncController?.add('同步完成 $done/$total');
      }
      Future.delayed(const Duration(seconds: 3), () {
        _scheduleGiteeSyncController?.add('');
      });
    } catch (e) {
      _scheduleGiteeSyncController?.add('全量同步失败: $e');
    } finally {
      _allScheduleSyncing = false;
    }
  }

  /// 从 Gitee 拉取指定用户日程并合并到当前日期
  Future<bool> pullScheduleFromGitee({String? userCode}) async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.isEmpty) {
      _scheduleGiteeSyncController?.add('未配置同步 Token');
      return false;
    }

    final dateKey = _getDateKey(_currentDate);
    final code = userCode ?? _scheduleUser.code;
    try {
      _scheduleGiteeSyncController?.add('拉取中...');
      final result = await ScheduleGiteeService.pullSchedule(
        token: token,
        dateKey: dateKey,
        userCode: code,
      );
      if (result.notFound) {
        _scheduleGiteeSyncController?.add('远端无数据');
        Future.delayed(const Duration(seconds: 3), () {
          _scheduleGiteeSyncController?.add('');
        });
        return false;
      }
      if (!result.success || result.content == null) {
        _scheduleGiteeSyncController?.add(result.error ?? '拉取失败');
        return false;
      }

      final List<dynamic> slotList;
      try {
        slotList = json.decode(result.content!) as List<dynamic>;
      } catch (_) {
        _scheduleGiteeSyncController?.add('解析失败');
        return false;
      }

      final daySlots = _dailySlots.putIfAbsent(dateKey, _generateInitialSlots);
      for (final item in slotList) {
        final map = Map<String, dynamic>.from(item as Map);
        final idx = map['i'] as int;
        if (idx >= 0 && idx < daySlots.length) {
          daySlots[idx].recorded = true;
          daySlots[idx].label = map['l'] as String?;
          daySlots[idx].categoryId = map['cid'] as String?;
          if (map['c'] != null) {
            daySlots[idx].color = Color(map['c'] as int);
          }
        }
      }
      _allSlotsDirty = true;
      if (!_remoteViewEnabled) _saveData();
      notifyListeners();
      _scheduleGiteeSyncController?.add('已同步');
      Future.delayed(const Duration(seconds: 3), () {
        _scheduleGiteeSyncController?.add('');
      });
      return true;
    } catch (e) {
      _scheduleGiteeSyncController?.add('拉取失败: $e');
      return false;
    }
  }

  /// 切换查看对方日程。打开时显示纯远端数据；关闭时恢复本地数据。
  Future<void> toggleRemoteScheduleView() async {
    final dateKey = _getDateKey(_currentDate);
    if (_remoteViewEnabled) {
      // 关闭：恢复本地数据
      if (_remoteViewBackup.containsKey(dateKey)) {
        final slots = _dailySlots[dateKey] ?? _generateInitialSlots();
        final backupList = json.decode(_remoteViewBackup.remove(dateKey)!) as List<dynamic>;
        for (final s in slots) {
          s.recorded = false;
          s.label = null;
          s.categoryId = null;
          s.color = null;
          s.isFromCalendar = false;
          s.calendarEventId = null;
        }
        for (final item in backupList) {
          final map = Map<String, dynamic>.from(item as Map);
          final idx = map['i'] as int;
          if (idx >= 0 && idx < slots.length) {
            slots[idx].recorded = true;
            slots[idx].label = map['l'] as String?;
            slots[idx].categoryId = map['cid'] as String?;
            if (map['c'] != null) slots[idx].color = Color(map['c'] as int);
            if (map['fc'] == true) slots[idx].isFromCalendar = true;
            if (map['eid'] != null) slots[idx].calendarEventId = map['eid'] as String?;
          }
        }
        _allSlotsDirty = true;
        _saveData();
        notifyListeners();
      }
      _remoteViewEnabled = false;
    } else {
      // 打开：备份本地，清空当前日期，拉取纯远端数据
      final localSlots = _dailySlots[dateKey];
      if (localSlots != null) {
        _remoteViewBackup[dateKey] = json.encode(_serializeRecordedSlots(localSlots));
      } else {
        _remoteViewBackup[dateKey] = json.encode(<Map<String, dynamic>>[]);
      }
      // 先清空当前日期，确保只显示远端数据
      final daySlots = _dailySlots.putIfAbsent(dateKey, _generateInitialSlots);
      for (final s in daySlots) {
        s.recorded = false;
        s.label = null;
        s.categoryId = null;
        s.color = null;
        s.isFromCalendar = false;
        s.calendarEventId = null;
      }
      // 拉取对方的文件（独立文件，无需过滤）
      final otherCode = _scheduleUser.code == 'g' ? 'j' : 'g';
      await pullScheduleFromGitee(userCode: otherCode);
      // 拉取后不保存到本地持久化
      _remoteViewEnabled = true;
    }
    notifyListeners();
  }

  /// 本地与云端日历不一致时标记（与是否已登录无关）
  void _markPendingSync() {
    _pendingSyncDates.add(_getDateKey(_currentDate));
    _syncDirty = true;
    _markScheduleGiteePending();
  }

  void _clearPendingSyncForCurrentDate() {
    final key = _getDateKey(_currentDate);
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
    if (!_googleCalendarSyncEnabled) {
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

        bool pullOk = await pullGoogleCalendarForDate(_currentDate,
            notify: false);
        final success = await GoogleCalendarService.syncSlotsToGoogle(
            slots, _currentDate);

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
  void removeEventFromSlot(int index) {
    if (index >= 0 && index < slots.length) {
      if (slots[index].recorded) {
        final wasFromCalendar = slots[index].isFromCalendar;
        _saveSnapshot();
        if (wasFromCalendar) {
          _dismissCalendarImportAt(index);
        } else {
          _clearSlot(index);
          final dateKey = _getDateKey(_currentDate);
          _slotsDirty.add(dateKey);
          _targetStatsCache.invalidateDate(dateKey);
          _markPendingSync();
          _scheduleCalendarSync();
          _saveData();
          notifyListeners();
          _targetStatsChangedController.add(null);  // 通知目标统计变化
        }
      }
    }
  }

  void _clearSlot(int index) => _clearSlotAt(slots, index);

  void _clearSlotAt(List<TimeSlot> daySlots, int index) {
    daySlots[index].recorded = false;
    daySlots[index].label = null;
    daySlots[index].categoryId = null;
    daySlots[index].color = null;
    daySlots[index].isFromCalendar = false;
    daySlots[index].calendarEventId = null;
  }

  Future<void> _dismissCalendarImportAt(int index) async {
    final dateKey = _getDateKey(_currentDate);
    final daySlots = slots;

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
      final deleted =
          await GoogleCalendarService.deleteExternalEvent(eventId);
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

    _slotsDirty.add(dateKey);  // 标记当前日期为脏
    _calendarDirty = true;  // 忽略列表也变了
    _targetStatsCache.invalidateDate(dateKey);  // 失效该日期的缓存
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

  String _calendarBlockFingerprint(
      String title, DateTime start, DateTime end) {
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

  // --- Google 日历下拉 ---

  Future<void> pullGoogleCalendarForCurrentDate() async {
    if (!_googleCalendarSyncEnabled) return;
    await pullGoogleCalendarForDate(_currentDate);
  }

  /// 从 Google 拉取外部会议并合并到指定日期；未登录 Google 时返回 false
  Future<bool> pullGoogleCalendarForDate(DateTime date,
      {bool notify = true}) async {
    if (!_googleCalendarSyncEnabled) return false;
    if (!GoogleCalendarService.isSignedIn) return false;

    final blocks = await GoogleCalendarService.fetchExternalEvents(date);
    if (blocks == null) return false;
    final dateKey = _getDateKey(date);
    _mergeCalendarBlocks(dateKey, blocks, date);
    _slotsDirty.add(dateKey);
    _targetStatsCache.invalidateDate(dateKey);  // 失效该日期的缓存
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
              index: m['i'] as int,
              label: m['l'] as String? ?? '',
              categoryId: m['cid'] as String?,
              colorArgb: m['c'] as int?,
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
    _templatesDirty = true;  // 标记模板为脏
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

  DateTime get _yesterdayDate =>
      _currentDate.subtract(const Duration(days: 1));

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
  bool copyFromYesterday({ApplyTemplateMode mode = ApplyTemplateMode.fillEmptyOnly}) {
    final entries = _yesterdayCopyEntries();
    if (entries.isEmpty) return false;
    _applySlotEntries(entries, mode);
    return true;
  }

  void _applySlotEntries(List<TemplateSlot> entries, ApplyTemplateMode mode) {
    _saveSnapshot();

    final dateKey = _getDateKey(_currentDate);
    if (mode == ApplyTemplateMode.replaceAll) {
      _dailySlots[dateKey] = _generateInitialSlots();
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
      daySlots[entry.index].categoryId = entry.categoryId ??
          resolveCategoryIdForLabel(entry.label);
      daySlots[entry.index].isFromCalendar = false;
      daySlots[entry.index].calendarEventId = null;
      if (entry.colorArgb != null) {
        daySlots[entry.index].color = Color(entry.colorArgb!);
      }
    }

    _markPendingSync();
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null);  // 通知目标统计变化
    _scheduleCalendarSync();
  }

  void renameTemplate(String id, String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final index = _templates.indexWhere((t) => t.id == id);
    if (index == -1) return;
    _templates[index] = _templates[index].copyWith(name: trimmed);
    _templatesDirty = true;  // 标记模板为脏
    _saveData();
    notifyListeners();
  }

  void deleteTemplate(String id) {
    _templates.removeWhere((t) => t.id == id);
    _templatesDirty = true;  // 标记模板为脏
    _saveData();
    notifyListeners();
  }

  // --- 分类管理方法 (从 HomeScreen 移入) ---

  void addCategory(Category category) {
    _categories.add(category);
    _categoriesDirty = true;
    _invalidateLabelCategoryIdCache();  // 清除缓存
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

    _categories[index] = updated;
    _categoriesDirty = true;
    _invalidateLabelCategoryIdCache();  // 清除缓存
    _saveData();
    notifyListeners();
  }

  void hideSubCategory(int catIndex, String subCategory) {
    if (catIndex < 0 || catIndex >= _categories.length) return;
    final cat = _categories[catIndex];
    final newSubs = List<String>.from(cat.subCategories)..remove(subCategory);
    final newHidden = List<String>.from(cat.hiddenSubCategories)..add(subCategory);
    _categories[catIndex] = cat.copyWith(
      subCategories: newSubs,
      hiddenSubCategories: newHidden,
    );
    _categoriesDirty = true;  // 标记分类为脏
    _saveData();
    notifyListeners();
  }

  void restoreSubCategory(int catIndex, String subCategory) {
    if (catIndex < 0 || catIndex >= _categories.length) return;
    final cat = _categories[catIndex];
    final newHidden = List<String>.from(cat.hiddenSubCategories)..remove(subCategory);
    final newSubs = List<String>.from(cat.subCategories)..add(subCategory);
    _categories[catIndex] = cat.copyWith(
      subCategories: newSubs,
      hiddenSubCategories: newHidden,
    );
    _categoriesDirty = true;  // 标记分类为脏
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
    _allSlotsDirty = true;
    _targetsDirty = true;
    _templatesDirty = true;
    _targetStatsCache.invalidate();
    _invalidateLabelCategoryIdCache();
    _targetStatsChangedController.add(null);  // 通知目标统计变化
  }

  void _migrateToCategoryIds() {
    final labelMap = _labelToCategoryIdMap();
    var categoriesChanged = false;
    _categories = _categories.map((cat) {
      if (cat.id.isEmpty) {
        categoriesChanged = true;
        return cat.copyWith(
            id: DateTime.now().microsecondsSinceEpoch.toString());
      }
      return cat;
    }).toList();

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
      if (categoriesChanged) _categoriesDirty = true;
      if (slotsChanged) _allSlotsDirty = true;
      if (targetsChanged) _targetsDirty = true;
      _saveData();
    }
  }

  // --- 数据持久化逻辑 ---

  Future<void> _saveData() async {
    final previous = _ongoingSave;
    final save = _saveDataImpl();
    _ongoingSave = save;
    try {
      if (previous != null) await previous;
      await save;
    } finally {
      if (_ongoingSave == save) _ongoingSave = null;
    }
  }

  Future<void> _saveDataImpl() async {
    // Invalidate stats cache on any data change
    if (_slotsDirty.isNotEmpty || _allSlotsDirty) {
      _statsCache = null;
      _statsCacheKey = null;
    }

    final prefs = await SharedPreferences.getInstance();

    // 1. 保存分类（仅在变化时）
    if (_categoriesDirty) {
      List<String> catList = _categories.map((c) {
        return json.encode({
          'id': c.id,
          'name': c.name,
          'color': c.color.toARGB32(),
          'subCategories': c.subCategories,
          'hiddenSubCategories': c.hiddenSubCategories,
        });
      }).toList();
      await prefs.setStringList('categories', catList);
      _categoriesDirty = false;
    }

    // 2. 保存目标（仅在变化时）
    if (_targetsDirty) {
      List<String> targetList =
          _targets.map((t) => json.encode(t.toJson())).toList();
      await prefs.setStringList('targets', targetList);
      _targetsDirty = false;
    }

    // 3. 保存时间块（仅保存变化的日期）
    if (_allSlotsDirty) {
      // 全量保存所有时间块
      Map<String, dynamic> slotsJson = {};
      _dailySlots.forEach((dateKey, daySlots) {
        final recordedSlots = _serializeRecordedSlots(daySlots);
        if (recordedSlots.isNotEmpty) {
          slotsJson[dateKey] = recordedSlots;
        }
      });
      await prefs.setString('daily_slots', json.encode(slotsJson));
      _allSlotsDirty = false;
      _slotsDirty.clear();
    } else if (_slotsDirty.isNotEmpty) {
      // 增量保存：只保存变化的日期
      // 先加载现有数据
      String? slotsStr = prefs.getString('daily_slots');
      Map<String, dynamic> slotsJson = {};
      if (slotsStr != null) {
        try {
          slotsJson = json.decode(slotsStr) as Map<String, dynamic>;
        } catch (_) {}
      }
      // 更新变化的日期
      for (final dateKey in _slotsDirty) {
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
      _slotsDirty.clear();
    }

    // 4. 日程模板（仅在变化时）
    if (_templatesDirty) {
      await prefs.setString(
        'schedule_templates',
        json.encode(_templates.map((t) => t.toJson()).toList()),
      );
      _templatesDirty = false;
    }

    // 5. 已忽略的 Google 日历导入（仅在变化时）
    if (_calendarDirty) {
      final ignoredJson = <String, dynamic>{};
      _ignoredCalendarImports.forEach((dateKey, ids) {
        if (ids.isNotEmpty) ignoredJson[dateKey] = ids.toList();
      });
      await prefs.setString('ignored_calendar_imports', json.encode(ignoredJson));
      _calendarDirty = false;
    }

    // 6. 待同步日期（仅在变化时）
    if (_syncDirty) {
      await prefs.setStringList(
          'pending_sync_dates', _pendingSyncDates.toList());
      _syncDirty = false;
    }

    // 7. 分类展开状态（总是保存，因为体积小）
    await prefs.setString('category_expand_states', json.encode(_categoryExpandStates));

    await _refreshHomeWidget();
  }

  Future<void> _refreshHomeWidget() async {
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
    _categoriesDirty = true;
    _targetsDirty = true;
    _allSlotsDirty = true;
    _templatesDirty = true;
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
    _categories = (data['categories'] as List)
        .map((e) {
          final map = Map<String, dynamic>.from(e as Map);
          return Category(
            id: map['id'] as String?,
            name: map['name'] as String,
            color: Color(map['color'] as int),
            subCategories: List<String>.from(map['subCategories'] ?? []),
            hiddenSubCategories: List<String>.from(map['hiddenSubCategories'] ?? []),
          );
        })
        .toList();
    _ensureTempCategory();

    _targets
      ..clear()
      ..addAll(
        ((data['targets'] as List?) ?? [])
            .map((e) => Target.fromJson(Map<String, dynamic>.from(e as Map))),
      );

    _dailySlots.clear();
    _loadDailySlotsFromJson(Map<String, dynamic>.from(data['dailySlots'] as Map));

    _templates
      ..clear()
      ..addAll(
        ((data['scheduleTemplates'] as List?) ?? [])
            .map((e) =>
                ScheduleTemplate.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );

    _ignoredCalendarImports.clear();
    final ignored = data['ignoredCalendarImports'];
    if (ignored is Map) {
      ignored.forEach((dateKey, value) {
        _ignoredCalendarImports[dateKey as String] =
            Set<String>.from(value as List<dynamic>);
      });
    }

    _pendingSyncDates
      ..clear()
      ..addAll(
        ((data['pendingSyncDates'] as List?) ?? []).cast<String>(),
      );
  }

  void _ensureTempCategory() {
    if (!_categories.any((c) => c.name == '临时')) {
      _categories.add(Category(name: '临时', color: const Color(0xFF9E9E9E)));
    }
  }

  List<Category> _defaultCategories() => [
        Category(
            name: '学习',
            color: const Color(0xFFD4AF37),
            subCategories: ['阅读', '编程']),
        Category(
            name: '工作',
            color: const Color(0xFF9CB86A),
            subCategories: ['会议', '文档']),
        Category(name: '运动', color: const Color(0xFF4A90E2)),
        Category(name: '临时', color: const Color(0xFF9E9E9E)),
      ];

  void _loadDailySlotsFromJson(Map<String, dynamic> slotsJson) {
    slotsJson.forEach((dateKey, value) {
      final daySlots = _generateInitialSlots();
      for (final item in value as List<dynamic>) {
        final map = Map<String, dynamic>.from(item as Map);
        final idx = map['i'] as int;
        if (idx >= 0 && idx < daySlots.length) {
          daySlots[idx].recorded = true;
          daySlots[idx].label = map['l'] as String?;
          daySlots[idx].categoryId = map['cid'] as String?;
          if (map['c'] != null) {
            daySlots[idx].color = Color(map['c'] as int);
          }
          if (map['fc'] == true) {
            daySlots[idx].isFromCalendar = true;
          }
          if (map['eid'] != null) {
            daySlots[idx].calendarEventId = map['eid'] as String?;
          }
        }
      }
      _dailySlots[dateKey] = daySlots;
    });
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. 加载分类
    List<String>? catList = prefs.getStringList('categories');
    if (catList != null && catList.isNotEmpty) {
      _categories = catList.map((str) {
        Map<String, dynamic> map = json.decode(str);
        return Category(
          id: map['id'] as String?,
          name: map['name'],
          color: Color(map['color']),
          subCategories: List<String>.from(map['subCategories'] ?? []),
          hiddenSubCategories: List<String>.from(map['hiddenSubCategories'] ?? []),
        );
      }).toList();
      _ensureTempCategory();
    } else {
      _categories = _defaultCategories();
    }

    // 2. 加载目标
    List<String>? targetList = prefs.getStringList('targets');
    if (targetList != null) {
      _targets.clear();
      _targets.addAll(
          targetList.map((str) => Target.fromJson(json.decode(str))).toList());
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
              .map((e) =>
                  ScheduleTemplate.fromJson(e as Map<String, dynamic>))
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
          _ignoredCalendarImports[dateKey] =
              Set<String>.from(value as List<dynamic>);
        });
      } catch (e) {
        debugPrint("加载忽略日历列表出错: $e");
      }
    }

    // 6. 待同步日期
    _pendingSyncDates
      ..clear()
      ..addAll(prefs.getStringList('pending_sync_dates') ?? []);
    _googleCalendarSyncEnabled =
        prefs.getBool('google_calendar_sync_enabled') ?? true;
    _scheduleUser =
        DiaryKindX.fromCode(prefs.getString(_scheduleUserKey));

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

    _categories[fromIndex] = fromCat.copyWith(
      subCategories: fromCat.subCategories.where((s) => s != subName).toList(),
    );
    _categories[toIndex] = toCat.copyWith(
      subCategories: [...toCat.subCategories, subName],
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
    _categoriesDirty = true;
    _targetsDirty = true;
    _allSlotsDirty = true;
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

    _categoriesDirty = true;  // 标记分类为脏
    notifyListeners();
    _saveData();
  }

  void deleteCategory(int index) {
    final categoryId = _categories[index].id;
    _categories.removeAt(index);
    _categoriesDirty = true;
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
    _targetStatsChangedController.add(null);  // 通知目标统计变化
  }

  void updateTarget(Target newTarget) {
    int index = _targets.indexWhere((t) => t.id == newTarget.id);
    if (index != -1) {
      _targets[index] = newTarget;
      _targetsDirty = true;
      _saveData();
      notifyListeners();
      _targetStatsChangedController.add(null);  // 通知目标统计变化
    }
  }

  void deleteTarget(Target target) {
    _targets.remove(target);
    _targetsDirty = true;
    _saveData();
    notifyListeners();
    _targetStatsChangedController.add(null);  // 通知目标统计变化
  }

  void reorderTargets(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final Target item = _targets.removeAt(oldIndex);
    _targets.insert(newIndex, item);
    _targetsDirty = true;  // 标记目标为脏
    _saveData();
    notifyListeners();
  }

  /// 获取时间点目标在指定日期的状态
  TimePointStatus getTimePointStatus(Target target, DateTime date) {
    final dateKey = "${date.year}-${date.month}-${date.day}";
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
      return _dailySlots[dateKey]!
          .any((s) => slotMatchesTarget(s, target));
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
    if (target.period == "每周" || target.period == "本周") return target.frequencyCount;
    return dailyGoal * 7;
  }

  /// 获取目标的月目标次数
  int getTargetMonthlyGoal(Target target) {
    final dailyGoal = getTargetDailyGoal(target);
    if (target.period == "每天") return dailyGoal * 30;
    if (target.period == "每月" || target.period == "本月") return target.frequencyCount;
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
      return _statsCache!;
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
    return stats;
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

    return counts;
  }

  // 在 TimeProvider 类中添加
  Map<String, List<String>> getEventHistory(String eventName, int tabIndex) {
    Map<String, List<String>> history = {};

    // 确定起始日期
    DateTime now = DateTime.now();
    DateTime start;
    if (tabIndex == 0) {
      start = DateTime(now.year, now.month, now.day);
    } else if (tabIndex == 1) {
      start = now.subtract(const Duration(days: 7));
    } else if (tabIndex == 2) {
      start = DateTime(now.year, now.month - 1, now.day);
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

    // 遍历日期
    for (int i = 0; i <= now.difference(start).inDays; i++) {
      DateTime date = now.subtract(Duration(days: i));
      String dateKey = _getDateKey(date);

      if (_dailySlots.containsKey(dateKey)) {
        List<TimeSlot> daySlots = _dailySlots[dateKey]!;
        List<String> ranges = [];

        int j = 0;
        while (j < daySlots.length) {
          if (daySlots[j].recorded && daySlots[j].label == eventName) {
            int startIdx = j;
            while (j < daySlots.length &&
                daySlots[j].recorded &&
                daySlots[j].label == eventName) {
              j++;
            }
            // 转换索引为时间字符串，例如 "08:00 - 08:30"
            String startT =
                "${(startIdx ~/ 6).toString().padLeft(2, '0')}:${(startIdx % 6 * 10).toString().padLeft(2, '0')}";
            String endT =
                "${(j ~/ 6).toString().padLeft(2, '0')}:${(j % 6 * 10).toString().padLeft(2, '0')}";
            ranges.add("$startT - $endT");
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
        if (slot.recorded &&
            slot.label != null &&
            slot.label!.isNotEmpty) {
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

    final groups = <SearchRecordGroup>[];
    var current = endDay;

    while (!current.isBefore(startDay)) {
      final dateKey = _getDateKey(current);
      final daySlots = _dailySlots[dateKey];
      if (daySlots != null) {
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
          while (i < daySlots.length &&
              daySlots[i].recorded &&
              daySlots[i].label == label &&
              _slotMatchesSearchQuery(daySlots[i], queryLower)) {
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
          groups.add(SearchRecordGroup(date: current, entries: entries));
        }
      }
      current = current.subtract(const Duration(days: 1));
    }
    return groups;
  }
}
