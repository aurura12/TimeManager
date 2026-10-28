import 'dart:async';

import 'package:flutter/widgets.dart';

import '../utils/local_day_range.dart';
import 'main_tab_activity.dart';

/// 自然日切换时通知页面重建；隐藏页面和后台不保留定时器。
///
/// 计时方式与 TargetDayRefresh 一致：
/// - 页面可见且应用在前台时，定时到下一个零点；
/// - 跨日、回到前台、重新可见时都会补一次检查；
/// - 页面隐藏或切后台时取消定时器，避免空跑。
class DayChangeBoundary extends StatefulWidget {
  const DayChangeBoundary({
    super.key,
    required this.builder,
    this.onDayChanged,
    this.canHandleDayChange,
    this.clock,
  });

  final WidgetBuilder builder;

  /// 跨日时回调（旧的自然日 → 新的自然日）。
  ///
  /// 即使不传回调，组件本身也会在跨日时重建 [builder]，
  /// 供那些只在 build 里读取 `DateTime.now()` 的页面刷新「今日」状态。
  final void Function(DateTime previousDay, DateTime today)? onDayChanged;

  /// 页面暂时不能切日时保留通知；页面状态更新后会再次检查。
  final bool Function()? canHandleDayChange;

  final DateTime Function()? clock;

  @override
  State<DayChangeBoundary> createState() => _DayChangeBoundaryState();
}

class _DayChangeBoundaryState extends State<DayChangeBoundary>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _isActive = false;
  late DateTime _day;
  DateTime? _pendingPreviousDay;
  bool _checkScheduled = false;

  DateTime get _now => (widget.clock ?? DateTime.now)();
  bool get _isForeground {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _day = localDayOf(_now);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isActive = MainTabActivity.isActiveOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (_isActive) _scheduleDayCheck();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(DayChangeBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pendingPreviousDay != null && _isActive) _scheduleDayCheck();
  }

  void _scheduleDayCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    // 回调可能更新祖先页面或 Provider，必须等当前构建帧结束。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted || !_isActive) return;
      _checkDayChanged();
    });
  }

  void _checkDayChanged() {
    if (!_isActive || !_isForeground || !mounted) return;
    final today = localDayOf(_now);
    if (!isSameLocalDay(today, _day)) {
      if (widget.onDayChanged != null) _pendingPreviousDay ??= _day;
      _day = today;
      setState(() {});
    }
    final previousDay = _pendingPreviousDay;
    if (previousDay == null || !(widget.canHandleDayChange?.call() ?? true)) {
      return;
    }
    _pendingPreviousDay = null;
    widget.onDayChanged?.call(previousDay, today);
  }

  void _scheduleRefresh() {
    _timer?.cancel();
    _timer = null;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!_isActive ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    final now = _now;
    final nextMidnight = localDayOf(now).add(const Duration(days: 1));
    final delay = nextMidnight.difference(now);
    if (delay <= Duration.zero) return;
    _timer = Timer(delay, () {
      _timer = null;
      if (!mounted) return;
      _checkDayChanged();
      _scheduleRefresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _scheduleRefresh();
    if (state == AppLifecycleState.resumed && _isActive && mounted) {
      // 保留原来的「回到前台立即重算」行为（例如已过时间、达标状态）。
      setState(() {});
      _checkDayChanged();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
