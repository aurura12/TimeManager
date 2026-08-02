import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/screens/profile_screen.dart';
import '../providers/time_provider.dart';
import '../services/diary_local_store.dart';
import '../services/diary_search_service.dart';
import '../services/on_this_day_service.dart';
import '../widgets/on_this_day_sheet.dart';
import 'check_in_screen.dart';
import 'diary_screen.dart';
import 'home_screen.dart';
import 'target_screen.dart';
import 'travel_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;

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

    // 后台加载日记索引，保证首次启动也能读到已同步的日记
    _loadDiaryIndexInBackground();

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

  /// 后台加载日记搜索索引（App 启动时调用，避免首屏漏掉已同步日记）
  Future<void> _loadDiaryIndexInBackground() async {
    try {
      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.trim().isEmpty) return;
      if (!DiarySearchService.isLoaded && !DiarySearchService.isLoading) {
        DiarySearchService.loadInBackground(token);
      }
    } catch (_) {
      // 索引加载失败不影响主流程
    }
  }

  /// 等待日记索引加载完成（最多等待 15 秒，超时继续）
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
      if (!provider.isInitialLoadFinished) return; // 数据未就绪，等 notifyListeners 再触发

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

  static final List<Widget> _widgetOptions = <Widget>[
    const HomeScreen(),
    const DiaryScreen(),
    const TravelScreen(),
    const CheckInScreen(),
    const TargetScreen(),
    const ProfileScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _widgetOptions,
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.home), label: '记录'),
          BottomNavigationBarItem(
            icon: Icon(Icons.menu_book_outlined),
            label: '日记',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.card_travel), label: '出行'),
          BottomNavigationBarItem(
            icon: Icon(Icons.check_circle_outline),
            label: '打卡',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.flag), label: '目标'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        onTap: _onItemTapped,
      ),
    );
  }
}
