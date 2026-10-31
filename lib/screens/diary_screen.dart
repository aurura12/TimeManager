import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/diary_conflict.dart';
import '../models/diary_kind.dart';
import '../models/diary_search_result.dart';
import '../models/remote_sync_platform.dart';
import '../models/sync_center_state.dart';
import '../services/diary_gitee_service.dart';
import '../services/diary_local_store.dart';
import '../services/diary_sync_service.dart';
import '../services/diary_search_service.dart';
import '../services/app_identity_service.dart';
import '../services/diary_auto_sync_service.dart';
import '../services/sync_operation_lock.dart';
import '../services/sync_status_coordinator.dart';
import '../widgets/sync_status_button.dart';
import '../utils/app_lifecycle.dart';
import '../utils/diary_markdown.dart';
import '../utils/diary_remote_path_utils.dart';
import '../utils/haptics.dart';
import '../utils/local_day_range.dart';
import '../utils/swipe_navigation.dart';
import 'diary_conflict_screen.dart';
import 'diary_search_screen.dart';
import 'sync_center_screen.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/day_change_boundary.dart';
import '../widgets/desktop_shortcut_host.dart';

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({
    super.key,
    this.autoSyncService,
    this.syncService,
    this.initialKind,
    this.initialDate,
    this.openConflictOnLoad = false,
  });

  /// 从同步中心跳转时指定要打开的日期与分区。
  final DiaryKind? initialKind;
  final DateTime? initialDate;

  /// 打开页面后如果有冲突，直接进入冲突处理页。
  final bool openConflictOnLoad;

  /// 仅供测试注入；生产环境使用默认的 [DiaryAutoSyncService]。
  final DiaryAutoSyncService? autoSyncService;

  /// 仅供测试注入；生产环境用于冲突时的强制上传。
  final DiarySyncService? syncService;

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> with WidgetsBindingObserver {
  final TextEditingController _bodyController = TextEditingController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  DiaryKind _kind = DiaryKind.g;

  /// 设置中选定的当前身份，用于同步保护和只读提示
  DiaryKind? _selectedIdentityKind;
  DateTime _selectedDate = DateTime.now();
  DateTime? _startedAt;
  String? _token;
  bool _loading = true;
  bool _processing = false;
  bool _suppressBodyListener = false;
  Timer? _saveDebounce;
  bool _shortcutDateChanging = false;

  /// 自动上传排期：停止输入后触发，任何一次新编辑都会重新计时。
  Timer? _autoPushDebounce;
  bool _autoPushRunning = false;
  int _editRevision = 0;
  late final DiaryAutoSyncService _autoSync;
  late final DiarySyncService _syncService;
  static const Duration _autoPushDelay = Duration(seconds: 3);

  /// 编辑框区域：滑动切日要避开它，否则会抢走文字选择。
  final GlobalKey _editorAreaKey = GlobalKey();
  int? _swipePointer;
  Offset? _swipeStart;
  Duration? _swipeStartStamp;
  double _swipeDx = 0;
  double _swipeDy = 0;

  bool _isInsideEditor(Offset globalPosition) {
    final box = _editorAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size)
        .contains(globalPosition);
  }

  void _resetSwipe() {
    _swipePointer = null;
    _swipeStart = null;
    _swipeStartStamp = null;
    _swipeDx = 0;
    _swipeDy = 0;
  }

  void _onSwipePointerDown(PointerDownEvent event) {
    if (!_dateNavigationEnabled || _loading) return;
    // 只认触屏与触控笔：鼠标拖拽和触控板双指都不该翻日记。
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    if (_isInsideEditor(event.position)) return;
    _swipePointer = event.pointer;
    _swipeStart = event.position;
    _swipeStartStamp = event.timeStamp;
    _swipeDx = 0;
    _swipeDy = 0;
  }

  void _onSwipePointerMove(PointerMoveEvent event) {
    if (event.pointer != _swipePointer) return;
    final start = _swipeStart;
    if (start == null) return;
    _swipeDx = event.position.dx - start.dx;
    _swipeDy = event.position.dy - start.dy;
  }

  void _onSwipePointerUp(PointerUpEvent event) {
    if (event.pointer != _swipePointer) return;
    final startedAt = _swipeStartStamp;
    final elapsedMs = startedAt == null
        ? 0
        : (event.timeStamp - startedAt).inMilliseconds;
    final direction = resolveSwipeNavigation(
      dx: _swipeDx,
      dy: _swipeDy,
      velocityX: elapsedMs > 0 ? _swipeDx / elapsedMs * 1000 : 0.0,
    );
    _resetSwipe();
    if (direction == null || !_dateNavigationEnabled) return;
    playHaptic(context, HapticStrength.selection);
    _changeDateByShortcut(direction == SwipeNavigationDirection.next
        ? _selectedDate.add(const Duration(days: 1))
        : _selectedDate.subtract(const Duration(days: 1)));
  }

  void _onSwipePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _swipePointer) return;
    _resetSwipe();
  }

  Future<void> _changeDateByShortcut(DateTime date) async {
    if (_shortcutDateChanging || _loading || _processing) return;
    setState(() => _shortcutDateChanging = true);
    try {
      _saveDebounce?.cancel();
      await _switchContext(date: date);
    } on Object {
      _showMessage('切换日记日期失败，请重试');
    } finally {
      if (mounted) setState(() => _shortcutDateChanging = false);
    }
  }

  bool get _dateNavigationEnabled => !_processing && !_shortcutDateChanging;

  void _goToPreviousDay() => unawaited(
      _changeDateByShortcut(_selectedDate.subtract(const Duration(days: 1))));

  void _goToNextDay() => unawaited(
      _changeDateByShortcut(_selectedDate.add(const Duration(days: 1))));

  bool _remoteTreeLoading = false;
  String? _remoteTreeError;
  List<String> _remoteDiaryPaths = const [];
  Map<String, String> _remoteDiaryPathShas = {};
  DateTime? _remoteDiaryPathsFetchedAt;
  bool _remoteDiaryListingAvailable = false;
  final Map<String, ({String? path, String? sha, bool notFound})>
      _diaryRemoteBaselines = {};
  final Set<String> _expandedRemoteFolders = {};
  final Map<String, String> _contextRemotePathOverrides = {};
  bool _lastContextPathAmbiguous = false;
  int _contextRequestId = 0;
  bool _dirtySinceContextLoaded = false;
  bool _localSaveFailed = false;

  /// 按日期记录「远端已更新 + 本地未上传」的冲突，只存内存。
  final Map<String, DiaryConflictEntry> _conflicts = {};

  /// 冲突处理页打开期间不再触发自动上传与重复入口。
  bool _conflictResolving = false;

  /// 页面已销毁：异步收尾（离开页面时的补推）不能再排新的定时器。
  bool _disposed = false;

  DiaryConflictEntry? get _currentConflict =>
      _conflicts[_contextKey(_kind, _selectedDate)];
  static const Duration _remotePathsTtl = Duration(minutes: 3);
  Set<String> _gDiaryDateKeys = {};
  Set<String> _jDiaryDateKeys = {};
  late final StreamSubscription<void> _identitySubscription;

  /// 全局同步状态中心。允许为空：独立构建日记页时没有 Provider 树，
  /// 此时只跳过状态上报。
  SyncStatusCoordinator? _statusCoordinator;

  /// 日记按「身份 + 远端平台」隔离同步状态。
  String get _diarySyncScope =>
      '${_kind.code}:${RemoteSyncPlatform.gitee.name}';

  void _reportDiary(SyncOperationResult result) {
    _statusCoordinator?.report(
      SyncModule.diary,
      result,
      scope: _diarySyncScope,
      source: '日记页',
    );
  }

  void _beginDiarySync() {
    _statusCoordinator?.begin(
      SyncModule.diary,
      scope: _diarySyncScope,
      source: '日记页',
      message: '正在同步日记',
    );
  }

  void _markDiaryPending() {
    _statusCoordinator?.markPending(
      SyncModule.diary,
      uploadCount: 1,
      message: '有日记草稿待上传',
      source: '日记页',
      scope: _diarySyncScope,
    );
  }

  /// 停止输入后自动上传。日记的拉取本来就在进页面 / 切日时自动执行，
  /// 上传也用同一节奏，用户不需要再手动点同步。
  void _scheduleAutoPush() {
    // 页面销毁后不再排新的上传：离开页面时的那次补推还在飞，它回来时
    // 可能发现「期间有新编辑」，不能再装一个没人取消的定时器。
    if (_disposed) return;
    _autoPushDebounce?.cancel();
    _autoPushDebounce = Timer(_autoPushDelay, () {
      unawaited(_flushAutoPush());
    });
  }

  /// 立即补推一次；并发触发时只保留一次在途任务（由 service 去重）。
  ///
  /// 只有「本次推送成功，且推送期间没有新编辑」才把当前上下文标记为已同步，
  /// 否则下一次编辑、切日或回前台还会重试。
  Future<void> _flushAutoPush() async {
    _autoPushDebounce?.cancel();
    _autoPushDebounce = null;
    if (_autoPushRunning || !_dirtySinceContextLoaded) return;
    _autoPushRunning = true;
    final revision = _editRevision;
    final contextKey = _contextKey(_kind, _selectedDate);
    try {
      final result = await _autoSync.flush(coordinator: _statusCoordinator);
      if (result == null) return;
      if (result.status == SyncModuleStatus.conflict) {
        // 批量同步覆盖多个日期，冲突不一定属于当前这一天：补跑一次当前
        // 上下文的远端对比，把冲突记录到正确的日期上。
        unawaited(_refreshCurrentContextFromRemote(
          _contextRequestId,
          forcePathRefresh: true,
        ));
        return;
      }
      if (!result.succeeded) return;
      // 推送期间用户可能继续编辑或切到了别的日期：两种情况下都不能把
      // 「已同步」记到当前上下文上。
      if (revision != _editRevision ||
          contextKey != _contextKey(_kind, _selectedDate)) {
        _scheduleAutoPush();
        return;
      }
      _dirtySinceContextLoaded = false;
      if (mounted) setState(() {});
    } finally {
      _autoPushRunning = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoSync = widget.autoSyncService ?? DiaryAutoSyncService();
    _syncService = widget.syncService ?? DiarySyncService();
    _statusCoordinator = context.read<SyncStatusCoordinator?>();
    _bodyController.addListener(_onBodyChanged);
    _identitySubscription = AppIdentityService.changes.listen((_) {
      if (!mounted) return;
      setState(() => _selectedIdentityKind = AppIdentityService.personKind);
    });
    _loadInitial();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    _autoPushDebounce?.cancel();
    _autoPushDebounce = null;
    // 离开页面时把最后一次编辑落盘并补推一次；本地草稿即使推送失败也不会丢。
    unawaited(_saveDraftNow().then((_) => _flushAutoPush()));
    _identitySubscription.cancel();
    _bodyController.removeListener(_onBodyChanged);
    _bodyController.dispose();
    super.dispose();
  }

  /// 进入后台时立即落盘并补推，不再等 350ms 保存防抖和 3 秒上传排期。
  ///
  /// 桌面最小化走 hidden、移动端切后台走 paused；这里只做「有未保存修改」时
  /// 的补写，避免每次失焦都多写一遍。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isAppBackgroundedLifecycleState(state)) return;
    if (!_dirtySinceContextLoaded) return;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _autoPushDebounce?.cancel();
    _autoPushDebounce = null;
    unawaited(_saveDraftNow().then((_) => _flushAutoPush()));
  }

  Future<void> _loadInitial() async {
    final token = await DiaryLocalStore.loadToken();
    await AppIdentityService.load();
    final identityKind = AppIdentityService.personKind;
    _selectedIdentityKind = identityKind;
    final kind =
        widget.initialKind ?? identityKind ?? await DiaryLocalStore.loadPreferredKind();
    final initialDate = widget.initialDate;
    _token = token;
    _kind = kind;
    if (initialDate != null) {
      _selectedDate =
          DateTime(initialDate.year, initialDate.month, initialDate.day);
    }
    _dirtySinceContextLoaded = await _loadDraftForCurrentContext();
    if (!mounted) return;
    setState(() => _loading = false);
    final refresh = _refreshCurrentContextFromRemote(
      _contextRequestId,
      forcePathRefresh: widget.openConflictOnLoad,
    );
    if (widget.openConflictOnLoad) {
      // 从同步中心来：等远端对比完成，冲突已记录后再打开处理页。
      await refresh;
      if (!mounted) return;
      if (_currentConflict != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _currentConflict != null) {
            unawaited(_openConflictResolution());
          }
        });
      }
    } else {
      unawaited(refresh);
    }

    // 后台加载搜索缓存
    if (token != null && token.isNotEmpty) {
      DiarySearchService.loadInBackground(token);
    }
  }

  String _dateTextForFile(DateTime date) {
    return DateFormat('yyyy年M月d日').format(date);
  }

  String _contextKey(DiaryKind kind, DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${kind.code}_${d.year}$month$day';
  }

  String _kindLetter(DiaryKind kind) {
    return kind == DiaryKind.g ? 'G' : 'J';
  }

  String _fileNameFromPath(String path) {
    final segments = path.split('/');
    return segments.isEmpty ? path : segments.last;
  }

  bool _matchesKindAndDate(String path, DiaryKind kind, DateTime date) {
    final fileName = _fileNameFromPath(path);
    if (!fileName.toLowerCase().endsWith('.md')) return false;
    if (!fileName.startsWith(_kindLetter(kind))) return false;
    return fileName.contains(_dateTextForFile(date));
  }

  bool _isRemotePathsCacheFresh() {
    if (_remoteDiaryPathsFetchedAt == null) {
      return false;
    }
    return DateTime.now().difference(_remoteDiaryPathsFetchedAt!) <
        _remotePathsTtl;
  }

  void _applyRemoteDiaryListing(Map<String, String> pathShaMap) {
    _remoteDiaryPathShas = Map<String, String>.from(pathShaMap);
    _remoteDiaryPaths = _remoteDiaryPathShas.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    _remoteDiaryPathsFetchedAt = DateTime.now();
    _remoteDiaryListingAvailable = true;
  }

  void _rememberRemoteDiaryPathSha(String path, String sha) {
    _remoteDiaryPathShas[path] = sha;
    if (!_remoteDiaryPaths.contains(path)) {
      _remoteDiaryPaths = [..._remoteDiaryPaths, path]
        ..sort((a, b) => b.compareTo(a));
    }
    _remoteDiaryPathsFetchedAt = DateTime.now();
    _remoteDiaryListingAvailable = true;
  }

  void _setCurrentDiaryBaseline({
    required String? path,
    required String? sha,
    required bool notFound,
  }) {
    final key = _contextKey(_kind, _selectedDate);
    _diaryRemoteBaselines[key] = (
      path: notFound ? null : path,
      sha: notFound ? null : sha,
      notFound: notFound,
    );
    unawaited(
      DiaryLocalStore.saveRemoteBaseline(
        _kind,
        _selectedDate,
        path: notFound ? null : path,
        sha: notFound ? null : sha,
        notFound: notFound,
      ),
    );
  }

  Future<void> _updateDiaryDateKeys() async {
    final gKeys = <String>{};
    final jKeys = <String>{};
    for (final path in _remoteDiaryPaths) {
      final date = _parseDateFromPath(path);
      if (date != null) {
        final dateKey = DateFormat('yyyy-MM-dd').format(date);
        final fileName = _fileNameFromPath(path);

        // 尝试从缓存获取内容，检查正文是否为空
        final content = DiarySearchService.getCachedContentByPath(path);
        if (content != null) {
          final body = _extractBodyFromMarkdown(content);
          if (body.trim().isEmpty) continue; // 只有 yaml 头，没有实际正文
        }
        // 缓存未加载时，回退到文件存在检查（旧逻辑）

        if (fileName.startsWith('G')) {
          gKeys.add(dateKey);
        } else if (fileName.startsWith('J')) {
          jKeys.add(dateKey);
        }
      }
    }
    _gDiaryDateKeys = gKeys;
    _jDiaryDateKeys = jKeys;
  }

  Future<List<String>?> _fetchRemoteDiaryPathsSilently({
    bool forceRefresh = false,
  }) async {
    final token = (_token ?? '').trim();
    if (token.isEmpty) return null;
    if (!forceRefresh && _isRemotePathsCacheFresh()) {
      return _remoteDiaryPaths;
    }
    final listResult =
        await DiaryGiteeService.listDiaryPathsWithSha(token: token);
    if (!listResult.success) {
      _remoteDiaryListingAvailable = false;
      return null;
    }
    _applyRemoteDiaryListing(listResult.pathShaMap);
    await _updateDiaryDateKeys();
    return _remoteDiaryPaths;
  }

  Future<String?> _findRemotePathForCurrentContext(
      {bool refresh = true}) async {
    List<String> paths = _remoteDiaryPaths;
    if (refresh || paths.isEmpty) {
      final fetched =
          await _fetchRemoteDiaryPathsSilently(forceRefresh: refresh);
      if (fetched != null) {
        paths = fetched;
      }
    }
    if (paths.isEmpty) return null;

    final matched = paths
        .where((p) => _matchesKindAndDate(p, _kind, _selectedDate))
        .toList();
    if (matched.isEmpty) return null;
    final pinned =
        _contextRemotePathOverrides[_contextKey(_kind, _selectedDate)];
    if (pinned != null && matched.contains(pinned)) {
      _lastContextPathAmbiguous = false;
      return pinned;
    }
    if (matched.length > 1) {
      _lastContextPathAmbiguous = true;
      return null;
    }
    _lastContextPathAmbiguous = false;
    return matched.first;
  }

  Future<bool> _loadDraftForCurrentContext() async {
    final body = await DiaryLocalStore.loadDraftBody(_kind, _selectedDate);
    final startedAt =
        await DiaryLocalStore.loadDraftStartedAt(_kind, _selectedDate);
    final baseline = await DiaryLocalStore.loadRemoteBaseline(
      _kind,
      _selectedDate,
    );
    final pending = await DiaryLocalStore.isDraftPending(_kind, _selectedDate);
    final baselineKey = _contextKey(_kind, _selectedDate);
    if (baseline == null) {
      _diaryRemoteBaselines.remove(baselineKey);
    } else {
      _diaryRemoteBaselines[baselineKey] = (
        path: baseline.notFound ? null : baseline.path,
        sha: baseline.notFound ? null : baseline.sha,
        notFound: baseline.notFound,
      );
    }
    _suppressBodyListener = true;
    _bodyController.text = body ?? '';
    _suppressBodyListener = false;
    _startedAt = startedAt;
    return pending;
  }

  /// 落盘成功返回 true；失败时界面显示「本地保存失败」，切日期也会被拦下。
  Future<bool> _saveDraftNow() async {
    final bodySaved = await DiaryLocalStore.saveDraftBody(
      _kind,
      _selectedDate,
      _bodyController.text,
    );
    var startedSaved = true;
    if (_startedAt != null) {
      startedSaved = await DiaryLocalStore.saveDraftStartedAt(
          _kind, _selectedDate, _startedAt!);
    }
    final saved = bodySaved && startedSaved;
    if (_localSaveFailed != !saved) {
      if (mounted) {
        setState(() => _localSaveFailed = !saved);
      } else {
        _localSaveFailed = !saved;
      }
    }
    return saved;
  }

  void _onBodyChanged() {
    if (_suppressBodyListener) return;
    _startedAt ??= DateTime.now();
    _dirtySinceContextLoaded = true;
    _editRevision++;
    unawaited(DiaryLocalStore.markDraftPending(_kind, _selectedDate));
    _markDiaryPending();
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 350), () {
      _saveDraftNow();
      if (mounted) setState(() {});
    });
    _scheduleAutoPush();
  }

  void _insertCurrentTime() {
    final now = DateTime.now();
    final timeStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final text = _bodyController.text;
    final selection = _bodyController.selection;
    final offset = selection.isValid ? selection.start : text.length;

    final before = text.substring(0, offset);
    final after = text.substring(offset);
    final insertStr = before.isEmpty ? timeStr : '\n$timeStr';

    _bodyController.text = '$before$insertStr\n$after';
    _bodyController.selection =
        TextSelection.collapsed(offset: offset + insertStr.length + 1);
  }

  Future<void> _switchContext({
    DiaryKind? kind,
    DateTime? date,
  }) async {
    // 保存失败时不能切换：切走会把编辑框内容换成另一天的草稿，未落盘的文字就丢了。
    if (!await _saveDraftNow()) {
      _showMessage('本地保存失败，暂时无法切换日记，请检查存储空间');
      return;
    }
    // 切走前补推当前这篇，避免「写了一半就换日期」永远不上传。
    unawaited(_flushAutoPush());
    _contextRequestId++;
    final requestId = _contextRequestId;

    if (kind != null) {
      _kind = kind;
      await DiaryLocalStore.savePreferredKind(kind);
    }
    if (date != null) {
      _selectedDate = DateTime(date.year, date.month, date.day);
    }

    _dirtySinceContextLoaded = await _loadDraftForCurrentContext();
    if (!mounted || requestId != _contextRequestId) return;
    setState(() {});

    _refreshCurrentContextFromRemote(requestId, forcePathRefresh: false);
  }

  Future<void> _refreshCurrentContextFromRemote(
    int requestId, {
    required bool forcePathRefresh,
  }) async {
    final token = (_token ?? '').trim();
    if (token.isEmpty) return;
    if (!mounted || requestId != _contextRequestId) return;

    var remotePath =
        await _findRemotePathForCurrentContext(refresh: forcePathRefresh);
    if (!mounted || requestId != _contextRequestId) return;
    if (remotePath == null && !forcePathRefresh) {
      // 缓存没命中时再强制刷新一次远程列表。
      remotePath = await _findRemotePathForCurrentContext(refresh: true);
      if (!mounted || requestId != _contextRequestId) return;
    }
    if (remotePath == null) {
      if (!_lastContextPathAmbiguous && _remoteDiaryListingAvailable) {
        _setCurrentDiaryBaseline(path: null, sha: null, notFound: true);
      }
      return;
    }

    // 直接从远端拉取，避免陈旧搜索缓存覆盖新内容
    final result =
        await DiaryGiteeService.pullDiary(token: token, path: remotePath);
    if (!result.success) return;
    if (!mounted || requestId != _contextRequestId) return;
    final contextKey = _contextKey(_kind, _selectedDate);
    if (_dirtySinceContextLoaded) {
      // 本地还有未上传的修改时不能覆盖编辑器；但远端如果已经变了要立刻
      // 记录冲突（带远端正文），否则用户只会在下一次自动上传时才知道。
      // 没有基线（这一天从没成功对过远端）也算需要确认：自动上传那边同样
      // 会判成冲突，页面不给入口就永远处理不掉。
      final baseline = _diaryRemoteBaselines[contextKey];
      final remoteMatchesLocal = normalizeDiaryBody(result.content!) ==
          normalizeDiaryBody(_bodyController.text);
      final remoteChanged = !remoteMatchesLocal &&
          (baseline == null ||
              baseline.notFound ||
              baseline.path != remotePath ||
              baseline.sha != result.sha);
      if (remoteChanged) {
        _rememberRemoteDiaryPathSha(remotePath, result.sha!);
        final entry = DiaryConflictEntry(
          kind: _kind,
          date: _selectedDate,
          remotePath: remotePath,
        );
        if (mounted) {
          setState(() => _conflicts[contextKey] = entry);
        } else {
          _conflicts[contextKey] = entry;
        }
        _reportDiary(SyncOperationResult.conflict(
          '远端日记已被其他设备更新，本地还有未上传的修改',
          conflictCount: 1,
          pendingUploadCount: 1,
          details: [remotePath],
        ));
        return;
      }
      if (baseline == null) {
        // 正文已经一致，只是从没记过基线：补一条，避免每次打开都重新比对。
        _rememberRemoteDiaryPathSha(remotePath, result.sha!);
        _setCurrentDiaryBaseline(
          path: remotePath,
          sha: result.sha,
          notFound: false,
        );
      }
      return;
    }
    if (_conflicts.remove(contextKey) != null && mounted) setState(() {});
    _rememberRemoteDiaryPathSha(remotePath, result.sha!);
    _setCurrentDiaryBaseline(
      path: remotePath,
      sha: result.sha,
      notFound: false,
    );
    final raw = result.content!;

    if (_dirtySinceContextLoaded) return;
    final body = _extractBodyFromMarkdown(raw);
    final startedAt = _parseStartedAtFromMarkdown(raw);
    _suppressBodyListener = true;
    _bodyController.text = body;
    _suppressBodyListener = false;
    _startedAt = startedAt ?? DateTime.now();
    _contextRemotePathOverrides[_contextKey(_kind, _selectedDate)] = remotePath;
    await _saveDraftNow();
    await DiaryLocalStore.clearDraftPending(_kind, _selectedDate);
    if (!mounted || requestId != _contextRequestId) return;
    setState(() {});
  }

  void _onDateSelected(DateTime date) async {
    await _switchContext(date: DateTime(date.year, date.month, date.day));
    if (!mounted) return;
    Navigator.pop(context);
  }

  void _showCalendarPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CalendarPickerSheet(
        selectedDate: _selectedDate,
        gDiaryDateKeys: _gDiaryDateKeys,
        jDiaryDateKeys: _jDiaryDateKeys,
        onDateSelected: _onDateSelected,
      ),
    );
  }

  Future<void> _changeKind(DiaryKind kind) async {
    // Windows 下允许自由切换查看对方分区（与文件树/搜索一致）；
    // 提交保护由自动上传前校验身份负责，实现"可查看不可修改"。
    if (_kind == kind) return;
    await _switchContext(kind: kind);
  }

  Future<void> _openSearch() async {
    final token = (_token ?? '').trim();
    if (token.isEmpty) {
      _showMessage('请先配置当前平台同步 Token');
      return;
    }

    // 如果索引未加载且未在加载中，触发加载
    if (!DiarySearchService.isLoaded && !DiarySearchService.isLoading) {
      DiarySearchService.loadInBackground(token);
    }

    if (!mounted) return;

    final result = await Navigator.push<DiarySearchResult>(
      context,
      MaterialPageRoute(builder: (_) => const DiarySearchScreen()),
    );

    if (result != null && mounted) {
      await _switchContext(
        kind: result.kind == 'g' ? DiaryKind.g : DiaryKind.j,
        date: result.date,
      );
    }
  }

  DateTime? _parseStartedAtFromMarkdown(String markdown) {
    final match = RegExp(r'^---\n([\s\S]*?)\n---\n?', multiLine: false)
        .firstMatch(markdown);
    if (match == null) return null;
    final frontMatter = match.group(1) ?? '';
    final dateLine = RegExp(r'^date:\s*(.+)$', multiLine: true)
        .firstMatch(frontMatter)
        ?.group(1)
        ?.trim();
    if (dateLine == null || dateLine.isEmpty) return null;
    try {
      return DateFormat('yyyy-MM-dd HH:mm:ss').parseStrict(dateLine);
    } catch (_) {
      return DateTime.tryParse(dateLine);
    }
  }

  String _extractBodyFromMarkdown(String markdown) {
    return stripDiaryFrontMatter(markdown);
  }

  DateTime? _parseDateFromPath(String path) {
    return parseDiaryDateFromRemotePath(path);
  }

  Future<void> _loadRemoteFileToEditor(String path) async {
    // 直接从远程仓库拉取，避免陈旧搜索缓存覆盖新内容
    final result =
        await DiaryGiteeService.pullDiary(token: _token!, path: path);
    if (!mounted) return;
    if (!result.success) {
      _showMessage(result.error ?? '加载远程文件失败');
      return;
    }
    final raw = result.content!;

    final body = _extractBodyFromMarkdown(raw);
    final startedAt = _parseStartedAtFromMarkdown(raw);

    final fileName = path.split('/').last;
    final isG = fileName.startsWith('G');
    final isJ = fileName.startsWith('J');
    if (isG || isJ) {
      final newKind = isG ? DiaryKind.g : DiaryKind.j;
      if (_kind != newKind) {
        _kind = newKind;
        await DiaryLocalStore.savePreferredKind(newKind);
      }
    }
    final parsedDate = _parseDateFromPath(path);
    if (parsedDate != null) {
      _selectedDate =
          DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
    }
    _contextRemotePathOverrides[_contextKey(_kind, _selectedDate)] = path;
    _rememberRemoteDiaryPathSha(path, result.sha!);
    _setCurrentDiaryBaseline(path: path, sha: result.sha, notFound: false);
    _contextRequestId++;
    _dirtySinceContextLoaded = false;

    _suppressBodyListener = true;
    _bodyController.text = body;
    _suppressBodyListener = false;
    _startedAt = startedAt ?? DateTime.now();
    await _saveDraftNow();
    await DiaryLocalStore.clearDraftPending(_kind, _selectedDate);
    if (!mounted) return;
    setState(() {});
    _showMessage('已载入：$path');
  }

  Future<void> _loadRemoteTree() async {
    if ((_token ?? '').trim().isEmpty) {
      setState(() {
        _remoteTreeError = '未配置当前平台同步 Token';
        _remoteTreeLoading = false;
      });
      return;
    }
    setState(() {
      _remoteTreeLoading = true;
      _remoteTreeError = null;
    });
    final listResult = await DiaryGiteeService.listDiaryPathsWithSha(
      token: _token!,
    );
    if (!mounted) return;
    if (listResult.success) {
      _applyRemoteDiaryListing(listResult.pathShaMap);
    } else {
      _remoteDiaryListingAvailable = false;
    }
    setState(() {
      _remoteTreeLoading = false;
      if (listResult.success) {
        _remoteTreeError = null;
      } else {
        _remoteTreeError = listResult.error ?? '读取远程列表失败';
      }
    });
    if (listResult.success) {
      await _updateDiaryDateKeys();
      if (mounted) setState(() {});
    }
  }

  Future<void> _openRemoteTreeDrawer() async {
    if (_processing) return;
    _scaffoldKey.currentState?.openDrawer();
    if (_remoteTreeLoading) return;
    if (_remoteDiaryPaths.isNotEmpty && _remoteTreeError == null) return;
    await _loadRemoteTree();
  }


  Future<void> _openPathFromTree(String path) async {
    Navigator.of(context).pop();
    setState(() => _processing = true);
    try {
      // 文件树也会替换编辑器，必须和切日期一样先确认当前草稿落盘。
      if (!await _saveDraftNow()) {
        _showMessage('本地保存失败，暂时无法切换日记，请检查存储空间');
        return;
      }
      _saveDebounce?.cancel();
      _saveDebounce = null;
      if (!mounted) return;
      await _loadRemoteFileToEditor(path);
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  List<_RemoteFileNode> _buildRemoteTree(List<String> paths) {
    final root = <String, _RemoteFileNode>{};
    for (final path in paths) {
      final segments = path.split('/').where((e) => e.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      Map<String, _RemoteFileNode> current = root;
      var currentPath = '';
      for (int i = 0; i < segments.length; i++) {
        final name = segments[i];
        currentPath = currentPath.isEmpty ? name : '$currentPath/$name';
        final isFile = i == segments.length - 1;
        final node = current.putIfAbsent(
          name,
          () => _RemoteFileNode(
            name: name,
            path: currentPath,
            isFile: isFile,
          ),
        );
        node.isFile = node.isFile && isFile;
        current = node.children;
      }
    }
    final list = root.values.toList();
    list.sort(_sortRemoteNodes);
    for (final node in list) {
      _sortChildren(node);
    }
    return list;
  }

  void _sortChildren(_RemoteFileNode node) {
    final children = node.children.values.toList();
    children.sort(_sortRemoteNodes);
    node.sortedChildren = children;
    for (final child in children) {
      _sortChildren(child);
    }
  }

  int _sortRemoteNodes(_RemoteFileNode a, _RemoteFileNode b) {
    if (a.isFile == b.isFile) {
      if (a.isFile) {
        return compareDiaryRemoteFilePaths(a.path, b.path);
      }
      return a.name.compareTo(b.name);
    }
    return a.isFile ? 1 : -1;
  }

  Widget _buildRemoteNodeWidget(_RemoteFileNode node) {
    if (node.isFile) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.description_outlined, size: 18),
        title: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => _openPathFromTree(node.path),
      );
    }
    final expanded = _expandedRemoteFolders.contains(node.path);
    return ExpansionTile(
      key: ValueKey(node.path),
      initiallyExpanded: expanded,
      leading: const Icon(Icons.folder_outlined, size: 18),
      title: Text(node.name),
      childrenPadding: const EdgeInsets.only(left: 12),
      onExpansionChanged: (value) {
        setState(() {
          if (value) {
            _expandedRemoteFolders.add(node.path);
          } else {
            _expandedRemoteFolders.remove(node.path);
          }
        });
      },
      children: [
        for (final child in node.sortedChildren) _buildRemoteNodeWidget(child),
      ],
    );
  }

  Widget _buildRemoteTreeContent() {
    if (_remoteTreeLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_remoteTreeError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_remoteTreeError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _loadRemoteTree,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_remoteDiaryPaths.isEmpty) {
      return const Center(child: Text('暂无远程日记文件'));
    }
    final roots = _buildRemoteTree(_remoteDiaryPaths);
    return ListView(
      children: [
        for (final node in roots) _buildRemoteNodeWidget(node),
      ],
    );
  }

  /// 用远端内容替换编辑器，并同步基线 / 搜索缓存 / 待上传标记。
  Future<void> _applyRemoteVersion({
    required String raw,
    required String path,
    required String sha,
  }) async {
    final body = _extractBodyFromMarkdown(raw);
    final startedAt = _parseStartedAtFromMarkdown(raw);
    _suppressBodyListener = true;
    _bodyController.text = body;
    _suppressBodyListener = false;
    _startedAt = startedAt ?? DateTime.now();
    _rememberRemoteDiaryPathSha(path, sha);
    _setCurrentDiaryBaseline(path: path, sha: sha, notFound: false);
    _dirtySinceContextLoaded = false;
    _conflicts.remove(_contextKey(_kind, _selectedDate));
    await _saveDraftNow();
    await DiaryLocalStore.clearDraftPending(_kind, _selectedDate);
    // 刷新搜索缓存并落盘，避免重启后读到旧内容。
    await DiarySearchService.updateCache(_kind.code, _selectedDate, raw);
  }

  /// 打开冲突处理页：先落盘，再拉一次最新远端，确保对比的是当前版本。
  Future<void> _openConflictResolution() async {
    if (_processing || _conflictResolving) return;
    final entry = _currentConflict;
    if (entry == null) return;
    if (_isReadOnlyContext) {
      _showMessage('当前分区只读，请切换回自己的分区后再处理冲突');
      return;
    }
    final token = (_token ?? '').trim();
    if (token.isEmpty) {
      _showMessage('请先配置当前平台同步 Token');
      return;
    }

    _saveDebounce?.cancel();
    _autoPushDebounce?.cancel();
    _autoPushDebounce = null;
    if (!await _saveDraftNow()) {
      _showMessage('本地保存失败，暂时无法处理冲突');
      return;
    }
    if (!mounted) return;

    setState(() => _processing = true);
    _conflictResolving = true;
    _beginDiarySync();
    try {
      // 和其他日记同步共用同一把锁：回前台的自动上传可能同时在读这一天。
      final pull = await SyncOperationLock.instance.run(
        SyncModule.diary,
        () => DiaryGiteeService.pullDiary(token: token, path: entry.remotePath),
      );
      if (!mounted) return;
      if (!pull.success && !pull.notFound) {
        _showMessage(pull.error ?? '读取远端内容失败');
        return;
      }
      final remoteRaw = pull.notFound ? '' : pull.content!;
      final remoteBody =
          remoteRaw.isEmpty ? '' : _extractBodyFromMarkdown(remoteRaw);
      final remoteSha = pull.notFound ? null : pull.sha;
      final decision = await Navigator.of(context).push<DiaryConflictDecision>(
        MaterialPageRoute(
          builder: (_) => DiaryConflictScreen(
            kind: _kind,
            date: _selectedDate,
            localBody: _bodyController.text,
            remoteBody: remoteBody,
            remoteSha: remoteSha,
          ),
        ),
      );
      if (decision == null || !mounted) return;
      await _applyConflictDecision(
        decision,
        entry: entry,
        remoteRaw: remoteRaw,
        remoteSha: remoteSha,
      );
    } finally {
      _conflictResolving = false;
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _applyConflictDecision(
    DiaryConflictDecision decision, {
    required DiaryConflictEntry entry,
    required String remoteRaw,
    required String? remoteSha,
  }) async {
    final contextKey = _contextKey(_kind, _selectedDate);
    if (decision is DiaryUseRemote) {
      if (remoteSha == null) {
        _showMessage('远端这篇已不存在，请改用本地或合并');
        return;
      }
      // 必须传完整的远端 Markdown：front matter 里的 date 决定这篇的归属日。
      await _applyRemoteVersion(
        raw: remoteRaw,
        path: entry.remotePath,
        sha: remoteSha,
      );
      _showMessage('已采用远端内容');
      _reportDiary(const SyncOperationResult.success(message: '日记已采用远端内容'));
      if (mounted) setState(() {});
      return;
    }

    if (decision is DiaryKeepLocal) {
      final result = await _syncService.overwriteRemote(
        kind: _kind,
        date: _selectedDate,
        path: entry.remotePath,
        body: _bodyController.text,
      );
      _afterOverwrite(result, contextKey: contextKey);
      return;
    }

    if (decision is DiaryUseMerged) {
      _suppressBodyListener = true;
      _bodyController.text = decision.body;
      _suppressBodyListener = false;
      _dirtySinceContextLoaded = true;
      _editRevision++;
      await DiaryLocalStore.markDraftPending(_kind, _selectedDate);
      if (!await _saveDraftNow()) {
        _showMessage('合并结果保存失败，请检查存储空间');
        return;
      }
      final result = await _syncService.overwriteRemote(
        kind: _kind,
        date: _selectedDate,
        path: entry.remotePath,
        body: decision.body,
        expectedRemoteSha: remoteSha,
        // 确认合并时远端还没有这篇：期间若被别人写出来，不能直接覆盖。
        expectRemoteAbsent: remoteSha == null,
      );
      _afterOverwrite(result, contextKey: contextKey);
    }
  }

  void _afterOverwrite(
    SyncOperationResult result, {
    required String contextKey,
  }) {
    if (result.succeeded) {
      _conflicts.remove(contextKey);
      _dirtySinceContextLoaded = false;
      _showMessage('已用本地内容覆盖远端');
      _reportDiary(const SyncOperationResult.success(message: '已用本地内容覆盖远端'));
      // 服务只返回结果，不含新 sha：刷新一次拿回基线，避免下一轮又报冲突。
      unawaited(_refreshCurrentContextFromRemote(
        _contextRequestId,
        forcePathRefresh: true,
      ));
    } else {
      _showMessage(result.message ?? '覆盖远端失败');
    }
    if (mounted) setState(() {});
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(text),
      ),
    );
  }

  String _kindDisplayName(DiaryKind kind) {
    return kind == DiaryKind.g ? '乖乖' : '晶晶';
  }

  bool get _isReadOnlyContext {
    return _selectedIdentityKind != null && _selectedIdentityKind != _kind;
  }

  String get _diaryStatusText {
    if (_processing) return '正在同步…';
    if (_isReadOnlyContext) return '只读查看模式';
    if (_localSaveFailed) return '本地保存失败，请重试';
    if (_currentConflict != null) return '远端已被其他设备更新';
    if (_bodyController.text.trim().isEmpty) return '今天还没有内容';
    if ((_token ?? '').trim().isEmpty) return '仅保存在本机';
    if (_dirtySinceContextLoaded) return '本地有未同步修改';
    return '草稿已保存，可同步';
  }

  IconData get _diaryStatusIcon {
    if (_processing) return Icons.sync;
    if (_isReadOnlyContext) return Icons.visibility_outlined;
    if (_localSaveFailed) return Icons.error_outline;
    if (_currentConflict != null) return Icons.sync_problem;
    if (_bodyController.text.trim().isEmpty) return Icons.edit_note_outlined;
    if ((_token ?? '').trim().isEmpty) return Icons.save_outlined;
    if (_dirtySinceContextLoaded) return Icons.edit_note_outlined;
    return Icons.cloud_done_outlined;
  }

  void _openSyncCenter() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const SyncCenterScreen(initialModule: SyncModule.diary),
      ),
    );
  }

  Widget _buildDiaryStatus(ColorScheme colorScheme) {
    final detail = _isReadOnlyContext
        ? '可刷新远端内容；切换回自己的分区后才能提交'
        : _currentConflict != null
            ? '本地修改仍保留；可继续编辑，或改用远端内容'
            : _localSaveFailed
                ? '内容仍在编辑框里，确认存储空间后继续输入会自动重试'
                : '输入内容会自动保存到本机';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        // 背景启用时跟随「界面不透明度」
        color: context.wallpaperFill(colorScheme.surfaceContainerHigh),
        borderRadius: AppRadius.controlAll,
      ),
      child: Row(
        children: [
          Icon(
            _diaryStatusIcon,
            size: 18,
            color: _localSaveFailed || _currentConflict != null
                ? colorScheme.error
                : colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _diaryStatusText,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: AppText.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_currentConflict != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _processing ? null : _openConflictResolution,
                      child: const Text('处理冲突'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DayChangeBoundary(
        onDayChanged: _handleDayChanged,
        canHandleDayChange: () =>
            !_loading && !_processing && !_shortcutDateChanging,
        builder: (_) => DesktopShortcutHost(
          autofocus: true,
          onSearchPage: () => unawaited(_openSearch()),
          onPreviousDay: () => unawaited(_changeDateByShortcut(
              _selectedDate.subtract(const Duration(days: 1)))),
          onNextDay: () => unawaited(_changeDateByShortcut(
              _selectedDate.add(const Duration(days: 1)))),
          onToday: () => unawaited(_changeDateByShortcut(DateTime.now())),
          onEscape: () {
            if (_scaffoldKey.currentState?.isDrawerOpen != true) return false;
            _scaffoldKey.currentState!.closeDrawer();
            return true;
          },
          isAvailable: (action) =>
              action == DesktopShortcutActionType.escape ||
              (!_loading && !_processing && !_shortcutDateChanging),
          // Listener 不参与手势竞技场，不会抢编辑框内的文字选择；
          // 只负责旁听指针，用于左右滑动切日（编辑区内部自行排除）。
          child: Listener(
            onPointerDown: _onSwipePointerDown,
            onPointerMove: _onSwipePointerMove,
            onPointerUp: _onSwipePointerUp,
            onPointerCancel: _onSwipePointerCancel,
            child: _buildPage(context),
          ),
        ),
      );

  /// 跨过午夜时，如果还在写“今天”的日记，就切到新的一天继续写；
  /// 用户手动翻到别的日期时不打扰。
  void _handleDayChanged(DateTime previousDay, DateTime today) {
    if (!mounted) return;
    if (!isSameLocalDay(_selectedDate, previousDay)) return;
    unawaited(_changeDateByShortcut(today));
  }

  Widget _buildPage(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('日记')),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      key: _scaffoldKey,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: const Text('远程日记文件树'),
                trailing: IconButton(
                  tooltip: '刷新',
                  onPressed: _remoteTreeLoading ? null : _loadRemoteTree,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _buildRemoteTreeContent()),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        title: const Text('日记'),
        leading: ModalRoute.of(context)?.impliesAppBarDismissal == true
            ? const BackButton()
            : IconButton(
                tooltip: '浏览远程日记',
                onPressed: _openRemoteTreeDrawer,
                icon: const Icon(Icons.menu),
              ),
        actions: [
          if (ModalRoute.of(context)?.impliesAppBarDismissal == true)
            IconButton(
              tooltip: '浏览远程日记',
              onPressed: _openRemoteTreeDrawer,
              icon: const Icon(Icons.menu),
            ),
          IconButton(
            tooltip: desktopShortcutTooltip(
                context, '搜索日记', DesktopShortcutActionType.searchPage),
            onPressed: _openSearch,
            icon: const Icon(Icons.search),
          ),
          // 日记的拉取 / 上传都已经自动执行，这里只保留异常状态灯。
          SyncStatusButton(
            modules: const [SyncModule.diary],
            onPressed: _openSyncCenter,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SegmentedButton<DiaryKind>(
                        segments: const [
                          ButtonSegment(
                            value: DiaryKind.g,
                            label: Text('乖乖'),
                          ),
                          ButtonSegment(
                            value: DiaryKind.j,
                            label: Text('晶晶'),
                          ),
                        ],
                        selected: {_kind},
                        onSelectionChanged: _processing || _shortcutDateChanging
                            ? null
                            : (selection) {
                                if (selection.isNotEmpty) {
                                  unawaited(_changeKind(selection.first));
                                }
                              },
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: desktopShortcutTooltip(context, '前一天',
                                DesktopShortcutActionType.previousDay),
                            onPressed: _dateNavigationEnabled
                                ? _goToPreviousDay
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                _processing ? null : _showCalendarPicker,
                            icon: const Icon(Icons.calendar_today_outlined,
                                size: 16),
                            label: Text(
                              DateFormat('yyyy年M月d日').format(_selectedDate),
                            ),
                          ),
                          IconButton(
                            tooltip: desktopShortcutTooltip(context, '后一天',
                                DesktopShortcutActionType.nextDay),
                            onPressed:
                                _dateNavigationEnabled ? _goToNextDay : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ],
                  ),
                  // Windows 只读提示：查看对方日记分区时不可同步
                  if (_isReadOnlyContext) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: AppRadius.controlAll,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.visibility_outlined,
                              size: 16,
                              color: AppSemanticColors.readableOn(
                                  AppSemanticColors.warning,
                                  colorScheme.secondaryContainer)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '正在查看${_kindDisplayName(_kind)}的日记分区（只读，不可提交到远端）',
                              style: AppText.caption.copyWith(
                                color: colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _buildDiaryStatus(colorScheme),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Stack(
                      key: _editorAreaKey,
                      children: [
                        TextField(
                          controller: _bodyController,
                          maxLines: null,
                          expands: true,
                          readOnly: _isReadOnlyContext ||
                              _shortcutDateChanging ||
                              _processing,
                          textAlignVertical: TextAlignVertical.top,
                          decoration: InputDecoration(
                            hintText:
                                _isReadOnlyContext ? '当前分区仅供查看' : '写下今天发生的事…',
                            contentPadding: const EdgeInsets.only(
                              top: 16,
                              left: 12,
                              right: 44,
                              bottom: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: AppRadius.controlAll,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: IconButton(
                            tooltip: '插入当前时间',
                            onPressed: _isReadOnlyContext ||
                                    _shortcutDateChanging ||
                                    _processing
                                ? null
                                : _insertCurrentTime,
                            icon: const Icon(Icons.access_time, size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          ValueListenableBuilder<double>(
            valueListenable: DiarySearchService.progress,
            builder: (context, value, child) {
              if (value >= 1.0 || !DiarySearchService.isLoading) {
                return const SizedBox.shrink();
              }
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: context.wallpaperFill(colorScheme.surfaceContainerHigh),
                child: Row(
                  children: [
                    Icon(Icons.search,
                        size: 16, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: value > 0 ? value : null,
                        minHeight: 4,
                        borderRadius: AppRadius.gridAll,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      value > 0 ? '${(value * 100).toInt()}%' : '准备中...',
                      style: AppText.caption.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RemoteFileNode {
  final String name;
  final String path;
  bool isFile;
  final Map<String, _RemoteFileNode> children;
  List<_RemoteFileNode> sortedChildren;

  _RemoteFileNode({
    required this.name,
    required this.path,
    required this.isFile,
  })  : children = <String, _RemoteFileNode>{},
        sortedChildren = const [];
}

class _CalendarPickerSheet extends StatefulWidget {
  const _CalendarPickerSheet({
    required this.selectedDate,
    required this.gDiaryDateKeys,
    required this.jDiaryDateKeys,
    required this.onDateSelected,
  });

  final DateTime selectedDate;
  final Set<String> gDiaryDateKeys;
  final Set<String> jDiaryDateKeys;
  final Function(DateTime) onDateSelected;

  @override
  State<_CalendarPickerSheet> createState() => _CalendarPickerSheetState();
}

class _CalendarPickerSheetState extends State<_CalendarPickerSheet> {
  late DateTime _calendarMonth;

  @override
  void initState() {
    super.initState();
    _calendarMonth = DateTime(
      widget.selectedDate.year,
      widget.selectedDate.month,
      1,
    );
  }

  void _changeMonth(int delta) {
    setState(() {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month + delta,
        1,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final year = _calendarMonth.year;
    final month = _calendarMonth.month;
    final firstDayOfMonth = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final startWeekday = firstDayOfMonth.weekday;
    final today = DateTime.now();
    final todayKey = DateFormat('yyyy-MM-dd').format(today);
    final selectedKey = DateFormat('yyyy-MM-dd').format(widget.selectedDate);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: BoxDecoration(
        color: AppSurfaces.of(context).overlay,
        borderRadius: const BorderRadius.vertical(top: AppRadius.rSheet),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: AppRadius.gridAll,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: '上个月',
                onPressed: () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Text(
                '$year年$month月',
                style: AppText.sectionTitle,
              ),
              IconButton(
                tooltip: '下个月',
                onPressed: () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: ['一', '二', '三', '四', '五', '六', '日']
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: AppText.caption.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.0,
            children: List.generate(42, (index) {
              final dayOffset = index - (startWeekday - 1);
              if (dayOffset < 0 || dayOffset >= daysInMonth) {
                return const SizedBox.shrink();
              }
              final day = dayOffset + 1;
              final date = DateTime(year, month, day);
              final dateKey = DateFormat('yyyy-MM-dd').format(date);
              final isSelected = dateKey == selectedKey;
              final isToday = dateKey == todayKey;
              final hasGDiary = widget.gDiaryDateKeys.contains(dateKey);
              final hasJDiary = widget.jDiaryDateKeys.contains(dateKey);
              final hasDiary = hasGDiary || hasJDiary;

              return GestureDetector(
                onTap: () => widget.onDateSelected(date),
                child: Container(
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: isSelected ? colorScheme.primaryContainer : null,
                    border: isToday
                        ? Border.all(color: colorScheme.primary, width: 1.5)
                        : null,
                    borderRadius: AppRadius.badgeAll,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$day',
                        style: AppText.body.copyWith(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected
                              ? colorScheme.onPrimaryContainer
                              : null,
                        ),
                      ),
                      if (hasDiary)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (hasGDiary)
                              Container(
                                margin: const EdgeInsets.only(top: 2, right: 1),
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: AppSemanticColors.identityGuaiGuai,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            if (hasJDiary)
                              Container(
                                margin: const EdgeInsets.only(top: 2, left: 1),
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: AppSemanticColors.identityJingJing,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppSemanticColors.identityGuaiGuai,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              const Text('乖乖', style: AppText.caption),
              const SizedBox(width: 16),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppSemanticColors.identityJingJing,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              const Text('晶晶', style: AppText.caption),
            ],
          ),
        ],
      ),
    );
  }
}
