import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../utils/local_day_range.dart';
import '../utils/timeline_geometry.dart';
import 'main_tab_activity.dart';

/// 「现在」的小标记。
///
/// 只在今天这一列显示一个小圆点：网格每小时一行、横向 6 格各 10 分钟，
/// 所以圆点横向落在当前分钟按比例换算出的一格内位置，纵向贴在这一格的
/// 底边（行内居中的事件名不会被压住）；不做整行红线——整天铺一条线会
/// 盖住时间块本身的色块，视觉噪声太大。
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

    const size = AppSizes.nowMarkerSize;
    // 这一小时行的底边：圆点贴底放置，避开行内上下居中的事件名。
    final rowBottomY = timelineYForMinutes(
      (now.hour + 1) * 60,
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
              final top = rowBottomY - size - offset;
              if (top < -size || top > constraints.maxHeight) {
                return const SizedBox.shrink();
              }
              // 整点 / 59 分时圆点会压在行边缘，一半被裁掉，横向夹一下
              final maxLeft = math.max(0.0, constraints.maxWidth - size);
              final left = (timelineXForMinute(
                        now.minute,
                        rowWidth: constraints.maxWidth,
                      ) -
                      size / 2)
                  .clamp(0.0, maxLeft)
                  .toDouble();
              return Stack(
                children: [
                  Positioned(
                    key: const ValueKey('current-time-marker'),
                    left: left,
                    top: top,
                    child: Semantics(
                      label: '当前时间',
                      child: Container(
                        width: size,
                        height: size,
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
