import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../utils/motion.dart';

/// 值变化时给同一棵子树套一次淡入。
///
/// 与 `AnimatedSwitcher` 的区别：**不换 key、不换子树**，只是同一个 Element
/// 的透明度过渡。所以 `IndexedStack` 的页面保活、时间网格的滚动位置、日记
/// 编辑器的 GlobalKey 都不会被破坏。
///
/// 用于切 Tab、切日期这类「内容原地换了一批数据」的场景。刻意不做位移：
/// 网格与不参与包裹的时间轴刻度错位会被读成渲染 bug。
class ValueChangeTransition extends StatefulWidget {
  const ValueChangeTransition({
    super.key,
    required this.value,
    required this.child,
  });

  /// 变化时触发淡入的标识（日期、Tab、视图模式等）。
  final Object? value;

  final Widget child;

  @override
  State<ValueChangeTransition> createState() => _ValueChangeTransitionState();
}

class _ValueChangeTransitionState extends State<ValueChangeTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.transition,
    value: 1,
  );
  late final CurvedAnimation _opacity =
      CurvedAnimation(parent: _controller, curve: AppMotion.curve);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // initState 读不到 MediaQuery，时长只能在这里同步。
    _controller.duration = appMotionDuration(context);
    // 隐藏的分页里 ticker 是静音的，动画会停在起点；切回来时直接给最终态，
    // 避免用户看到一次「迟到」的淡入。
    if (_controller.isAnimating && !TickerMode.valuesOf(context).enabled) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(ValueChangeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    if (appMotionDuration(context) == Duration.zero) {
      _controller.value = 1;
      return;
    }
    // 按住方向键连续切日时不要每次从头再来，否则页面会长时间停在接近全透明。
    if (_controller.isAnimating) return;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

/// 列表条目新增时的一次淡入 + 轻微上移。
///
/// 只在页面显式标记的那一条上播放（`playing`），不做「挂载即播放」：
/// `ListView.builder` 的离屏子项重建会让滚动时反复淡入，无 key 的列表里
/// State 还会随位置迁移。
class ListItemEntrance extends StatefulWidget {
  const ListItemEntrance({
    super.key,
    required this.playing,
    required this.child,
    this.onEnd,
  });

  /// 这一条是否本次新增（由页面在新增成功后置位，播完由 [onEnd] 清掉）。
  final bool playing;

  final Widget child;

  /// 入场播完时回调，页面用它清掉「本次新增」标记。
  final VoidCallback? onEnd;

  @override
  State<ListItemEntrance> createState() => _ListItemEntranceState();
}

class _ListItemEntranceState extends State<ListItemEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.transition,
    value: 1,
  );
  late final CurvedAnimation _progress =
      CurvedAnimation(parent: _controller, curve: AppMotion.curve);
  bool _played = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = appMotionDuration(context);
    _playIfNeeded();
  }

  @override
  void didUpdateWidget(ListItemEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    _playIfNeeded();
  }

  void _playIfNeeded() {
    if (_played || !widget.playing) return;
    _played = true;
    _controller.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted) return;
      widget.onEnd?.call();
    });
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final progress = _progress.value;
        return Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset(0, AppMotion.listEnterOffset * (1 - progress)),
            child: child,
          ),
        );
      },
    );
  }
}

/// 列表条目删除时先收高淡出，塌到 0 之后才真正删数据。
///
/// 用 `TweenAnimationBuilder` 的 `onEnd` 而不是定时器：`flutter_test` 会在
/// 用例结束时断言没有待触发的 Timer，而 ticker 驱动的动画能被
/// `pumpAndSettle` 自然推完。
///
/// `removing` 回落（删除失败回滚）时高度会自己长回去，页面只需要把标记置空。
///
/// 退场动画播到一半就被卸载（切视图、列表重建、页面销毁）时
/// `TweenAnimationBuilder` 不会再回调 `onEnd`，删除永远不会提交，页面的
/// 「待删」标记也会卡住、把后续删除全部拦掉。这里在 [dispose] 里帧末补发一次
/// [onInterrupted]，语义等价于删除失败回滚：数据不动，页面把标记置空让行
/// 恢复。补发只走一次——正常塌陷后再卸载不会重复触发。
class ListItemRemoval extends StatefulWidget {
  const ListItemRemoval({
    super.key,
    required this.removing,
    required this.onCollapsed,
    this.onInterrupted,
    required this.child,
  });

  final bool removing;

  /// 收高动画塌到 0 时回调一次；页面在这里执行真正的删除。
  final VoidCallback onCollapsed;

  /// 退场动画没播完就被卸载时补发一次；页面在这里把「待删」标记置空。
  ///
  /// 删除不提交，等价于删除失败回滚。页面回调需自行判 `mounted`——
  /// 页面整体销毁时补发发生在销毁之后。不传则打断时静默放弃
  /// （不适用于「待删」标记会卡住删除入口的页面）。
  final VoidCallback? onInterrupted;

  final Widget child;

  @override
  State<ListItemRemoval> createState() => _ListItemRemovalState();
}

class _ListItemRemovalState extends State<ListItemRemoval> {
  /// 本轮退场是否已发出 [ListItemRemoval.onCollapsed]。
  bool _collapsed = false;

  @override
  void didUpdateWidget(ListItemRemoval oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 回滚 / 打断后同一行会复用，允许下一轮退场重新回调。
    if (!widget.removing) _collapsed = false;
  }

  @override
  void dispose() {
    if (widget.removing && !_collapsed) {
      final onInterrupted = widget.onInterrupted;
      if (onInterrupted != null) {
        // 卸载可能发生在构建 / 布局阶段，直接调父级 setState 会炸；
        // 推到帧末再补发。
        WidgetsBinding.instance.addPostFrameCallback((_) => onInterrupted());
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 1, end: widget.removing ? 0 : 1),
      duration: appMotionDuration(context),
      curve: AppMotion.curve,
      onEnd: () {
        if (!widget.removing || _collapsed) return;
        _collapsed = true;
        widget.onCollapsed();
      },
      builder: (context, value, child) {
        final content = Align(
          alignment: Alignment.topCenter,
          heightFactor: value,
          // Align 会把父级的紧宽度放宽，不加这个会让卡片瞬间变窄。
          child: SizedBox(width: double.infinity, child: child),
        );
        return IgnorePointer(
          ignoring: widget.removing,
          child: Opacity(
            opacity: value,
            child: widget.removing ? ClipRect(child: content) : content,
          ),
        );
      },
      child: widget.child,
    );
  }
}
