import 'dart:async';

import '../utils/platform_features.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/screens/profile_screen.dart';
import '../models/schedule_sync_progress.dart';
import '../providers/time_provider.dart';
import '../services/diary_search_service.dart';
import '../services/on_this_day_service.dart';
import '../theme/app_theme.dart';
import '../utils/adaptive.dart';
import '../widgets/on_this_day_sheet.dart';
import '../widgets/schedule_sync_progress_banner.dart';
import 'check_in_screen.dart';
import 'diary_screen.dart';
import 'home_screen.dart';
import 'target_screen.dart';
import 'travel_screen.dart';

/// 底部导航 / 侧边导航的一项。图标分选中态与未选中态，
/// 保证浅色、深色下选中状态都清晰。
class _NavEntry {
  const _NavEntry({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _MainTab {
  const _MainTab({required this.navigation, required this.builder});

  final _NavEntry navigation;
  final Widget Function() builder;
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;

  late final List<_MainTab> _tabs;
  late final List<Widget?> _tabPages;
  final Set<int> _builtTabIndices = <int>{};

  // 「记录」页用 IndexedStack 常驻，离开 Tab 不会 dispose，
  // 所以刷子模式要靠这个 key 主动退出。
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();

  // 那年今日弹窗状态
  String? _onThisDayShownDateKey; // 本次会话已弹过的日期（跨午夜时重置）
  bool _onThisDayChecking = false; // 正在检查中（防并发重复触发）
  static const _lastShownDateKey = 'on_this_day_last_shown_date';

  late final TimeProvider _timeProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 在 initState 保存 Provider 引用，dispose 中不再使用 context（树已不稳定）
    _timeProvider = context.read<TimeProvider>();
    _timeProvider.addListener(_tryShowOnThisDay);
    _tabs = _buildTabs();
    _tabPages = List<Widget?>.filled(_tabs.length, null);

    // 第一帧后也尝试一次（此时数据可能已就绪）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryShowOnThisDay();
    });
  }

  @override
  void dispose() {
    _timeProvider.removeListener(_tryShowOnThisDay);
    WidgetsBinding.instance.removeObserver(this);
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
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _timeProvider.onAppBackgrounded();
    }
  }

  Future<void> _tryShowOnThisDay() async {
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

  List<_MainTab> _buildTabs() {
    final tabs = <_MainTab>[
      _MainTab(
        navigation: const _NavEntry(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          label: '记录',
        ),
        builder: () => HomeScreen(key: _homeKey),
      ),
      _MainTab(
        navigation: const _NavEntry(
          icon: Icons.menu_book_outlined,
          selectedIcon: Icons.menu_book,
          label: '日记',
        ),
        builder: () => const DiaryScreen(),
      ),
      _MainTab(
        navigation: const _NavEntry(
          icon: Icons.card_travel_outlined,
          selectedIcon: Icons.card_travel,
          label: '出行',
        ),
        builder: () => const TravelScreen(),
      ),
      _MainTab(
        navigation: const _NavEntry(
          icon: Icons.check_circle_outline,
          selectedIcon: Icons.check_circle,
          label: '打卡',
        ),
        builder: () => const CheckInScreen(),
      ),
    ];

    // 平台过滤发生在建立 Tab 列表时，后续导航和 IndexedStack 共用这份列表，
    // 因而桌面端移除「目标」后不会留下一个错位的索引。
    if (!isDesktopPlatform) {
      tabs.add(
        _MainTab(
          navigation: const _NavEntry(
            icon: Icons.flag_outlined,
            selectedIcon: Icons.flag,
            label: '目标',
          ),
          builder: () => const TargetScreen(),
        ),
      );
    }

    tabs.add(
      _MainTab(
        navigation: const _NavEntry(
          icon: Icons.person_outline,
          selectedIcon: Icons.person,
          label: '我的',
        ),
        builder: () => const ProfileScreen(),
      ),
    );
    return tabs;
  }

  void _ensureTabBuilt(int index) {
    if (index < 0 ||
        index >= _tabs.length ||
        _builtTabIndices.contains(index)) {
      return;
    }
    _tabPages[index] = _tabs[index].builder();
    _builtTabIndices.add(index);
  }

  List<Widget> _buildTabPages() {
    return List<Widget>.generate(
      _tabs.length,
      (index) => _tabPages[index] ?? const SizedBox.shrink(),
      growable: false,
    );
  }

  void _onItemTapped(int index) {
    if (index < 0 || index >= _tabs.length) return;

    // 离开「记录」页时退出刷子模式，避免回到该页还带着刷子
    if (_selectedIndex == 0 && index != 0) {
      _homeKey.currentState?.exitBrushMode();
    }
    setState(() {
      _selectedIndex = index;
      _ensureTabBuilt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final safeIndex = _selectedIndex.clamp(0, _tabs.length - 1);
    _ensureTabBuilt(safeIndex);
    final options = _buildTabPages();
    final items = _tabs.map((tab) => tab.navigation).toList(growable: false);
    final scheduleSyncProgress =
        context.select<TimeProvider, ScheduleSyncProgress?>(
            (p) => p.scheduleSyncProgress);
    // iPad 宽屏使用左侧导航栏，手机/分屏窄栏保持底部导航
    if (isWideTablet(context)) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: safeIndex,
              onDestinationSelected: _onItemTapped,
              labelType: NavigationRailLabelType.all,
              leading: const SizedBox(height: 8),
              destinations: [
                for (final item in items)
                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.selectedIcon),
                    label: Text(item.label),
                  ),
              ],
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: surfaces.border,
            ),
            Expanded(
              child: _buildContentStack(
                options: options,
                safeIndex: safeIndex,
                progress: scheduleSyncProgress,
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      body: _buildContentStack(
        options: options,
        safeIndex: safeIndex,
        progress: scheduleSyncProgress,
      ),
      // 顶部一条弱边框，和内容区拉开层级（颜色与圆角统一走主题）
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: surfaces.panel,
          border: Border(top: BorderSide(color: surfaces.border)),
        ),
        child: NavigationBar(
          selectedIndex: safeIndex,
          onDestinationSelected: _onItemTapped,
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
      ),
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
