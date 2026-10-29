import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../utils/local_day_range.dart';
import '../utils/timeline_geometry.dart';
import 'main_tab_activity.dart';

/// 「现在」的小标记。
///
/// 只在今天这一列显示一个小圆点，随分钟沿左侧缓慢下移；不做整行红线——
/// 整天铺一条线会盖住时间块本身的色块，视觉噪声太大。
///
/// 计时与可见性门控照起床卡片的做法：保活 Tab 隐藏、切后台时停表。
class CurrentTimeMarker extends StatefulWidget {
  const CurrentTimeMarker({
    super.key,
    required this.controller,
    required this.date,
    this.clock,
  });

  /// 网格的滚动控制器：标记要贴着内容移动。
  final ScrollController controller;

  /// 这一列对应的日期；不是今天就什么都不画。
  final DateTime date;

  /// 测试注入的时钟。
  final DateTime Function()? clock;

  @override
  State<CurrentTimeMarker> createState() => _CurrentTimeMarkerState();
}

class _CurrentTimeMarkerState extends State<CurrentTimeMarker>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _isActive = true;

  DateTime get _now => (widget.clock ?? DateTime.now)();

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
    _refreshTimer();
  }

  void _refreshTimer() {
    _timer?.cancel();
    _timer = null;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_isActive &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _refreshTimer();
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    if (!isSameLocalDay(widget.date, now)) return const SizedBox.shrink();

    final y = timelineYForMinutes(
      minutesOfDayOf(now),
      rowExtent: AppSizes.gridRow,
      topPadding: AppSpacing.sm,
    );
    final color = Theme.of(context).colorScheme.error;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final offset =
            widget.controller.hasClients ? widget.controller.offset : 0.0;
        return IgnorePointer(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final top = y - offset - AppSizes.nowMarkerSize / 2;
              if (top < -AppSizes.nowMarkerSize ||
                  top > constraints.maxHeight) {
                return const SizedBox.shrink();
              }
              return Stack(
                children: [
                  Positioned(
                    key: const ValueKey('current-time-marker'),
                    left: AppSpacing.xs,
                    top: top,
                    child: Semantics(
                      label: '当前时间',
                      child: Container(
                        width: AppSizes.nowMarkerSize,
                        height: AppSizes.nowMarkerSize,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
