import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/target_progress_calculator.dart';
import 'main_tab_activity.dart';

/// 自然日切换时重建目标状态；隐藏页面和后台不保留定时器。
class TargetDayRefresh extends StatefulWidget {
  const TargetDayRefresh({super.key, required this.builder, this.clock});

  final WidgetBuilder builder;
  final DateTime Function()? clock;

  @override
  State<TargetDayRefresh> createState() => _TargetDayRefreshState();
}

class _TargetDayRefreshState extends State<TargetDayRefresh>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _isActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isActive = MainTabActivity.isActiveOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    _timer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!_isActive ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    final now = (widget.clock ?? DateTime.now)();
    _timer = Timer(TargetProgressCalculator.nextDay(now).difference(now), () {
      if (!mounted) return;
      setState(() {});
      _scheduleRefresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _scheduleRefresh();
    if (state == AppLifecycleState.resumed && _isActive) setState(() {});
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
