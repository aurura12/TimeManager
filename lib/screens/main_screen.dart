import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/screens/profile_screen.dart';
import '../models/main_tab_id.dart';
import '../models/global_search_result.dart';
import '../models/schedule_sync_progress.dart';
import '../providers/main_tab_provider.dart';
import '../providers/desktop_layout_provider.dart';
import '../providers/on_this_day_popup_provider.dart';
import '../providers/time_provider.dart';
import '../services/app_log_service.dart';
import '../services/diary_auto_sync_service.dart';
import '../services/diary_local_store.dart';
import '../services/check_in_reminder_service.dart';
import '../services/diary_reminder_diagnostics.dart';
import '../services/diary_reminder_service.dart';
import '../services/diary_search_service.dart';
import '../services/on_this_day_service.dart';
import '../services/sync_status_coordinator.dart';
import '../services/time_block_reminder_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/adaptive.dart';
import '../utils/app_lifecycle.dart';
import '../utils/app_snack_bar.dart';
import '../utils/platform_features.dart';
import '../widgets/data_failure_banner.dart';
import '../widgets/main_tab_activity.dart';
import '../widgets/desktop_shortcut_host.dart';
import '../widgets/main_tab_navigation.dart';
import '../widgets/motion_transitions.dart';
import '../widgets/on_this_day_sheet.dart';
import '../widgets/schedule_sync_progress_banner.dart';
import 'app_log_screen.dart';
import 'check_in_screen.dart';
import 'diary_screen.dart';
import 'home_screen.dart';
import 'global_search_screen.dart';
import 'target_screen.dart';
import 'travel_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => MainScreenState();
}

class MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  MainTabId? _selectedTab;
  LocalHistoryEntry? _hiddenTabHistory;

  late final Map<MainTabId, Widget Function()> _tabBuilders;
  late final List<Widget?> _tabPages;

  // 「记录」页用 IndexedStack 常驻，离开 Tab 不会 dispose，
  // 所以刷子模式要靠这个 key 主动退出。
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  final _profileKey = GlobalKey<ProfileScreenState>();
  final _shortcutFocus = FocusNode(debugLabel: '主页面快捷键');

  void openSettings() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    _hiddenTabHistory?.remove();
    _onItemTapped(MainTabId.profile);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _profileKey.currentState?.openSettings();
    });
  }

  /// 点时间块提醒后落到「记录」页，并把视图切到事件所在日期。
  ///
  /// 记录页本身跟随 provider 的 currentDate，不需要再传参；「记录」被隐藏时
  /// 走临时切换（返回键回「我的」），保持与「更多功能」一致。
  void openRecordAtDate(DateTime date) {
    if (!mounted) return;
    _hiddenTabHistory?.remove();
    _timeProvider.goToDate(date);
    if (_mainTabProvider.visibleTabs.contains(MainTabId.record)) {
      _onItemTapped(MainTabId.record);
    } else {
      _openHiddenTab(MainTabId.record);
    }
  }

  void _searchCurrentPage() {
    final type = switch (_selectedTab) {
      MainTabId.record => GlobalSearchContentType.timeRecord,
      MainTabId.diary => GlobalSearchContentType.diary,
      MainTabId.travel => GlobalSearchContentType.travel,
      MainTabId.checkIn => GlobalSearchContentType.checkIn,
      MainTabId.target => GlobalSearchContentType.target,
      _ => GlobalSearchContentType.all,
    };
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'global-search'),
      builder: (_) => GlobalSearchScreen(initialContentType: type),
    ));
  }

  // 那年今日弹窗状态
  String? _onThisDayShownDateKey; // 本次会话已弹过的日期（跨午夜时重置）
  bool _onThisDayChecking = false; // 正在检查中（防并发重复触发）
  bool _reminderSourceReady = false; // 时间块数据是否已就绪（用于识别就绪边沿）
  static const _lastShownDateKey = 'on_this_day_last_shown_date';

  late final TimeProvider _timeProvider;
  late final MainTabProvider _mainTabProvider;
  late final OnThisDayPopupProvider? _onThisDayPopup;
  late final SyncStatusCoordinator? _syncCoordinator;
  late final DiaryAutoSyncService _diaryAutoSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 在 initState 保存 Provider 引用，dispose 中不再使用 context（树已不稳定）
    _timeProvider = context.read<TimeProvider>();
    _syncCoordinator = context.read<SyncStatusCoordinator?>();
    // 可空泛型：没有注册该 Provider 的宿主（部分测试）按默认「自动弹出」处理。
    _onThisDayPopup = context.read<OnThisDayPopupProvider?>();
    // 日记上传不依赖日记页是否打开：冷启动和回前台都补推一次遗留草稿。
    _diaryAutoSync = DiaryAutoSyncService();
    _timeProvider.addListener(_tryShowOnThisDay);
    _timeProvider.addListener(_seedTimeBlockReminderPlan);
    // 从「仅手动查看」切回自动弹出时，当天若还没弹过就立刻补一次。
    _onThisDayPopup?.addListener(_tryShowOnThisDay);
    _tabBuilders = {
      MainTabId.record: () => HomeScreen(key: _homeKey),
      MainTabId.diary: () => const DiaryScreen(),
      MainTabId.travel: () => const TravelScreen(),
      MainTabId.checkIn: () => const CheckInScreen(),
      MainTabId.target: () => const TargetScreen(),
      MainTabId.profile: () =>
          ProfileScreen(key: _profileKey, onOpenHiddenTab: _openHiddenTab),
    };
    _tabPages = List<Widget?>.filled(MainTabId.values.length, null);
    _mainTabProvider = context.read<MainTabProvider>();
    _mainTabProvider.addListener(_onTabSettingsChanged);
    if (_mainTabProvider.isLoaded) {
      _selectedTab = _mainTabProvider.visibleTabs.first;
    }
    // 日记索引不能等用户第一次打开“日记”页才加载，否则启动后的“那年今日”
    // 和全局搜索会漏掉只存在于远端缓存中的历史日记。
    unawaited(_loadDiaryIndexInBackground());

    // 第一帧后也尝试一次（此时数据可能已就绪）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryShowOnThisDay();
      _seedTimeBlockReminderPlan();
      unawaited(_diaryAutoSync.flush(coordinator: _syncCoordinator));
    });
  }

  Future<void> _loadDiaryIndexInBackground() async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.trim().isEmpty) return;
    await DiarySearchService.loadInBackground(token);
  }

  @override
  void dispose() {
    final hiddenTabHistory = _hiddenTabHistory;
    _hiddenTabHistory = null;
    hiddenTabHistory?.remove();
    _timeProvider.removeListener(_tryShowOnThisDay);
    _timeProvider.removeListener(_seedTimeBlockReminderPlan);
    _onThisDayPopup?.removeListener(_tryShowOnThisDay);
    _mainTabProvider.removeListener(_onTabSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _shortcutFocus.dispose();
    super.dispose();
  }

  /// 等待由日记页或日记搜索触发的索引加载完成（最多等待 15 秒）。
  Future<void> _waitForDiaryIndex() async {
    if (DiarySearchService.isLoaded || !DiarySearchService.isLoading) return;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!DiarySearchService.isLoaded && DiarySearchService.isLoading) {
      if (DateTime.now().isAfter(deadline)) return;
      // 等一小段再轮询，避免忙等
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App 回到前台时检查日期变化：跨午夜时允许当天再次弹出
      _tryShowOnThisDay();
      unawaited(_timeProvider.onAppResumed());
      unawaited(_refreshReminders());
      // 后台期间可能写过日记（或被系统杀掉前没来得及上传），回前台补推一次。
      unawaited(_diaryAutoSync.flush(coordinator: _syncCoordinator));
    } else if (isAppBackgroundedLifecycleState(state)) {
      _timeProvider.onAppBackgrounded();
    }
  }

  /// 先导入后台期间的原生触发结果，再做一次幂等的排程自检。
  /// 这样「到点到底响没响」会立刻出现在运行日志里，不必等下次冷启动。
  Future<void> _refreshReminders() async {
    try {
      await DiaryReminderDiagnostics.importPendingEvents();
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '原生提醒日志导入失败',
        source: DiaryReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      // 未初始化或非 Android 时会同步短路，不影响既有测试
      await DiaryReminderService.ensureScheduled();
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '写日记提醒恢复自检失败',
        source: DiaryReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      // 打卡提醒只用本地偏好自检（不加载整份打卡文档）；
      // 权威的"目标是否还存在"由打卡页打开时用完整列表对齐
      await CheckInReminderService.reconcile();
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '打卡提醒恢复自检失败',
        source: CheckInReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      await TimeBlockReminderService.reconcile(
        force: true,
        trigger: TimeBlockReminderTrigger.resume,
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '时间块提醒恢复自检失败',
        source: TimeBlockReminderService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 时间块数据从「不可用」变成「可用」时排一轮提醒。
  ///
  /// 覆盖三种边沿：启动（provider 加载完成）、切身份（数据换了一套）、
  /// 退出「查看对方日程」。不用定时器，避免测试与后台常驻负担。
  void _seedTimeBlockReminderPlan() {
    if (!mounted) return;
    final ready = _timeProvider.isInitialLoadFinished &&
        _timeProvider.isTimeBlockReminderSourceReady;
    if (!ready) {
      _reminderSourceReady = false;
      return;
    }
    if (_reminderSourceReady) return;
    _reminderSourceReady = true;
    unawaited(
      TimeBlockReminderService.reconcile(
        force: true,
        trigger: TimeBlockReminderTrigger.startup,
      ),
    );
  }

  Future<void> _tryShowOnThisDay() async {
    // 用户选了「仅手动查看」→ 不自动弹层（「记录回顾 → 那年今日」仍可查看）
    if (!(_onThisDayPopup?.autoShow ?? true)) return;
    // 正在检查中 → 跳过（防并发：notifyListeners 多次触发时防止弹两次）
    if (_onThisDayChecking) return;
    if (!mounted) return;
    _onThisDayChecking = true;
    try {
      final provider = _timeProvider;
      if (!provider.isInitialLoadFinished) {
        return; // 数据未就绪，等 notifyListeners 再触发
      }

      final now = DateTime.now();
      final todayKey = OnThisDayService.dateKeyOf(now);

      // 本次会话已弹过同一天 → 跳过
      if (_onThisDayShownDateKey == todayKey) return;

      // 今天已经弹过就不再弹（跨会话持久化判断）
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_lastShownDateKey) == todayKey) return;

      // 等待日记索引加载完成（提升日记命中率）
      await _waitForDiaryIndex();
      if (!mounted) return;

      // 收集三数据源（时间记录 + 日记 + 出行），任一有数据就弹
      final entries = await OnThisDayService.collectEntries(provider);
      if (!mounted) return;
      if (entries.isEmpty) return; // 往年同日无任何数据就不弹

      // 记录本次会话已弹，避免重复触发
      _onThisDayShownDateKey = todayKey;

      // 弹窗真正显示后再标记"今天已显示"（落盘）
      // 通过 onShown 回调在 showModalBottomSheet 完成动画后写入
      showOnThisDaySheet(
        context,
        entries: entries,
        month: now.month,
        day: now.day,
        onShown: () async {
          final p = await SharedPreferences.getInstance();
          await p.setString(_lastShownDateKey, todayKey);
        },
      );
    } finally {
      _onThisDayChecking = false;
    }
  }

  void _onTabSettingsChanged() {
    if (!mounted || !_mainTabProvider.isLoaded) return;
    final visibleTabs = _mainTabProvider.visibleTabs;
    final nextTab =
        _hiddenTabHistory != null || visibleTabs.contains(_selectedTab)
            ? _selectedTab!
            : visibleTabs.first;
    if (_selectedTab == MainTabId.record && nextTab != MainTabId.record) {
      _homeKey.currentState?.exitBrushMode();
    }
    setState(() => _selectedTab = nextTab);
  }

  void _openHiddenTab(MainTabId tab) {
    if (_hiddenTabHistory != null ||
        !_mainTabProvider.hiddenTabs.contains(tab)) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route == null) return;

    // 只临时切换内容，页面仍留在原来的 IndexedStack 中保活。
    // 本地路由历史让顶部返回键和系统返回都回到“我的”，不改变导航偏好。
    final history = LocalHistoryEntry(onRemove: () {
      if (!mounted || _hiddenTabHistory == null) return;
      if (_selectedTab == MainTabId.record) {
        _homeKey.currentState?.exitBrushMode();
      }
      setState(() {
        _hiddenTabHistory = null;
        _selectedTab = MainTabId.profile;
      });
    });
    _hiddenTabHistory = history;
    route.addLocalHistoryEntry(history);
    setState(() {
      _selectedTab = tab;
      _ensureTabBuilt(tab);
    });
  }

  void _ensureTabBuilt(MainTabId tab) {
    _tabPages[tab.index] ??= _tabBuilders[tab]!();
  }

  List<Widget> _buildTabPages() {
    return List<Widget>.generate(
      MainTabId.values.length,
      (index) => MainTabActivity(
        key: ValueKey(MainTabId.values[index]),
        isActive: MainTabId.values[index] == _selectedTab,
        child: ExcludeFocus(
          excluding: MainTabId.values[index] != _selectedTab,
          child: TickerMode(
            enabled: MainTabId.values[index] == _selectedTab,
            child: _tabPages[index] ?? const SizedBox.shrink(),
          ),
        ),
      ),
      growable: false,
    );
  }

  void _onItemTapped(MainTabId tab) {
    if (!_mainTabProvider.visibleTabs.contains(tab)) return;
    _shortcutFocus.requestFocus();

    // 离开「记录」页时退出刷子模式，避免回到该页还带着刷子
    if (_selectedTab == MainTabId.record && tab != MainTabId.record) {
      _homeKey.currentState?.exitBrushMode();
    }
    setState(() {
      _selectedTab = tab;
      _ensureTabBuilt(tab);
    });
  }

  @override
  Widget build(BuildContext context) => DesktopShortcutHost(
        onSearchPage: _searchCurrentPage,
        onOpenSettings: openSettings,
        onEscape: () =>
            _selectedTab == MainTabId.profile &&
            (_profileKey.currentState?.closeSettings() ?? false),
        onSelectTab: (index) {
          final tabs = _mainTabProvider.visibleTabs;
          if (_hiddenTabHistory == null && index < tabs.length) {
            _onItemTapped(tabs[index]);
          }
        },
        isAvailable: (action) {
          if (!_mainTabProvider.isLoaded) return false;
          if (action.name.startsWith('tab')) {
            final index = int.parse(action.name.substring(3)) - 1;
            return _hiddenTabHistory == null &&
                index < _mainTabProvider.visibleTabs.length;
          }
          return true;
        },
        child: Focus(
            focusNode: _shortcutFocus,
            autofocus: true,
            child: _buildPage(context)),
      );

  Widget _buildPage(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final wallpaperTheme = AppWallpaperTheme.of(context);
    final desktopLayout = context.watch<DesktopLayoutProvider?>();
    if (!_mainTabProvider.isLoaded ||
        (isDesktopPlatform && desktopLayout?.isLoaded == false)) {
      // 先读导航偏好，避免启动时构造已隐藏的页面或短暂显示默认顺序。
      return Scaffold(
        backgroundColor:
            wallpaperTheme.enabled ? Colors.transparent : surfaces.page,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final items = _mainTabProvider.visibleTabs;
    final selectedTab = _selectedTab!;
    final navigationIndex = items.indexOf(selectedTab);
    final showNavigation = _hiddenTabHistory == null;
    _ensureTabBuilt(selectedTab);
    final options = _buildTabPages();
    final scheduleSyncProgress =
        context.select<TimeProvider, ScheduleSyncProgress?>(
            (p) => p.scheduleSyncProgress);
    // 数据层故障统一挂在壳层：底部标签允许隐藏「记录」页，横幅放在记录页里会看不到
    final failure = context.select<
        TimeProvider,
        ({
          bool initFailed,
          String? initMessage,
          bool saveFailed,
          String? saveMessage
        })>(
      (p) => (
        initFailed: p.hasInitializationFailure,
        initMessage: p.initializationFailureMessage,
        saveFailed: p.hasLocalSaveFailure,
        saveMessage: p.localSaveFailureMessage,
      ),
    );
    return LayoutBuilder(builder: (context, constraints) {
      final useSideNavigation = isWideTablet(context) ||
          (isDesktopPlatform &&
              desktopLayout?.navigationLayout == DesktopNavigationLayout.side &&
              constraints.maxWidth >= AppSizes.desktopNavigationBreakpoint);
      final showSideNavigation = useSideNavigation && showNavigation;
      return Scaffold(
        backgroundColor:
            wallpaperTheme.enabled ? Colors.transparent : surfaces.page,
        // 始终使用同一个 Row/Expanded 结构，跨断点或切布局不重建 Tab。
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: showSideNavigation ? AppSizes.desktopNavigationWidth : 0,
              child: showSideNavigation
                  ? NavigationDrawer(
                      key: const ValueKey('main-side-navigation'),
                      backgroundColor: surfaces.panel,
                      indicatorColor:
                          context.wallpaperFill(surfaces.navSelected),
                      tilePadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      selectedIndex:
                          navigationIndex < 0 ? null : navigationIndex,
                      onDestinationSelected: (index) =>
                          _onItemTapped(items[index]),
                      header: const SizedBox(height: AppSpacing.md),
                      children: [
                        for (final item in items)
                          NavigationDrawerDestination(
                            icon: Icon(item.icon),
                            selectedIcon: Icon(item.selectedIcon),
                            label: Text(item.label),
                          ),
                      ],
                    )
                  : null,
            ),
            SizedBox(
              width: showSideNavigation ? AppSizes.hairline : 0,
              child: showSideNavigation
                  ? VerticalDivider(
                      width: AppSizes.hairline,
                      thickness: AppSizes.hairline,
                      color: surfaces.border,
                    )
                  : null,
            ),
            Expanded(
              // 故障横幅放在壳层内容区顶部：底部标签可以不显示「记录」页，
              // 挂在记录页里用户可能永远看不到。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (failure.initFailed)
                    DataFailureBanner(
                      title: '本地数据未能加载，编辑已暂停',
                      message: failure.initMessage,
                      actionLabel: '查看日志',
                      onAction: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const AppLogScreen(),
                        ),
                      ),
                    )
                  else if (failure.saveFailed)
                    DataFailureBanner(
                      title: '本地保存失败，最近的修改可能丢失',
                      message: failure.saveMessage,
                      actionLabel: '重试保存',
                      onAction: () => _retryLocalSave(_timeProvider),
                    ),
                  Expanded(
                    // 切 Tab 只淡入新页面：IndexedStack 的子树与 key 都不动，
                    // 页面状态（滚动位置、编辑器内容）照旧保活。
                    child: ValueChangeTransition(
                      value: selectedTab,
                      child: _buildContentStack(
                        options: options,
                        safeIndex: selectedTab.index,
                        progress: scheduleSyncProgress,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        // 顶部一条弱边框，和内容区拉开层级。
        bottomNavigationBar: showNavigation && !useSideNavigation
            ? Container(
                decoration: BoxDecoration(
                  color: surfaces.panel,
                  border: Border(top: BorderSide(color: surfaces.border)),
                ),
                child: NavigationBar(
                  backgroundColor:
                      wallpaperTheme.enabled ? Colors.transparent : null,
                  selectedIndex: navigationIndex,
                  onDestinationSelected: (index) => _onItemTapped(items[index]),
                  destinations: [
                    for (final item in items)
                      NavigationDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.selectedIcon),
                        label: item.label,
                        tooltip: item.label,
                      ),
                  ],
                ),
              )
            : null,
      );
    });
  }

  /// 「重试保存」：失败时给一次明确反馈，成功则由 Provider 广播让横幅消失。
  Future<void> _retryLocalSave(TimeProvider provider) async {
    final saved = await provider.retryLocalSave();
    if (saved || !mounted) return;
    showAppSnackBar(
      context,
      '仍然无法保存，请检查存储空间后重试',
      interruptUndo: true,
    );
  }

  Widget _buildContentStack({
    required List<Widget> options,
    required int safeIndex,
    required ScheduleSyncProgress? progress,
  }) {
    return Stack(
      children: [
        IndexedStack(
          index: safeIndex,
          children: options,
        ),
        if (progress != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ScheduleSyncProgressBanner(progress: progress),
          ),
      ],
    );
  }
}
