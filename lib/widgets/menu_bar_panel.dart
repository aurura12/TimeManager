import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/category.dart';
import '../providers/menu_bar_provider.dart';
import '../providers/time_provider.dart';
import '../services/app_identity_service.dart';
import '../services/menu_bar_target_store.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/app_snack_bar.dart';
import '../utils/menu_bar_summary.dart';
import '../utils/motion.dart';
import '../utils/timeline_geometry.dart';
import 'menu_bar_target_dial.dart';
import 'time_grid.dart';

/// 菜单栏点开后的小面板：记录页同款时间网格 + 选时间后升起的双转盘。
///
/// 复用记录页的 [TimeGrid]（45px 行高、一小时一行、6 个 10 分钟格），
/// 选完时间段松手后底部升起「左右双竖转盘」：左分类、右子事件，
/// 滚轮转动、停下自动写入；点中间项可立即写入。
class MenuBarPanel extends StatefulWidget {
  const MenuBarPanel({super.key});

  @override
  State<MenuBarPanel> createState() => _MenuBarPanelState();
}

class _MenuBarPanelState extends State<MenuBarPanel> {
  Timer? _clock;
  DateTime _now = DateTime.now();
  int? _selectionStart;
  int? _selectionEnd;
  int _selectionSerial = 0;
  bool _pointerDown = false;

  final GlobalKey _gridKey = GlobalKey();
  final ScrollController _axisController = ScrollController();
  final ScrollController _gridController = ScrollController();
  final MenuBarTargetStore _targetStore = MenuBarTargetStore();
  MenuBarTarget? _rememberedTarget;

  bool get _hasSelection => _selectionStart != null && _selectionEnd != null;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
    _axisController.addListener(_syncGridScroll);
    // 打开时把「现在」放在视口上 1/3，和记录页一致。
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToNow());
    unawaited(_loadRememberedTarget());
  }

  Future<void> _loadRememberedTarget() async {
    final target = await _targetStore.load();
    if (!mounted || target == null) return;
    setState(() => _rememberedTarget = target);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _axisController.removeListener(_syncGridScroll);
    _axisController.dispose();
    _gridController.dispose();
    super.dispose();
  }

  void _syncGridScroll() {
    if (!_gridController.hasClients) return;
    final target = _axisController.offset;
    if ((_gridController.offset - target).abs() > 0.5) {
      _gridController.jumpTo(target);
    }
  }

  void _scrollToNow() {
    if (!mounted || !_axisController.hasClients) return;
    final position = _axisController.position;
    if (!position.hasViewportDimension || position.viewportDimension <= 0) {
      return;
    }
    final target = timelineScrollOffsetForNow(
      minutesOfDay: minutesOfDayOf(_now),
      rowExtent: AppSizes.gridRow,
      topPadding: AppSpacing.sm,
      viewportExtent: position.viewportDimension,
      maxScrollExtent: position.maxScrollExtent,
    );
    if ((position.pixels - target).abs() < 1) return;
    _axisController.jumpTo(target);
  }

  /// 转盘升起后网格变矮，刚选中的行可能被裁到视口外，把它拉回来。
  void _ensureSelectionVisible() {
    if (!mounted || !_axisController.hasClients) return;
    final start = _selectionStart;
    final end = _selectionEnd;
    if (start == null || end == null) return;
    final firstRow = math.min(start, end) ~/ 6;
    final lastRow = math.max(start, end) ~/ 6;
    final position = _axisController.position;
    if (!position.hasViewportDimension || position.viewportDimension <= 0) {
      return;
    }
    final top = AppSpacing.sm + firstRow * AppSizes.gridRow;
    final bottom = AppSpacing.sm + (lastRow + 1) * AppSizes.gridRow;
    final viewTop = position.pixels;
    final viewBottom = viewTop + position.viewportDimension;
    double? target;
    if (top < viewTop) {
      target = top - AppSpacing.sm;
    } else if (bottom > viewBottom) {
      target = bottom - position.viewportDimension + AppSpacing.sm;
    }
    if (target == null) return;
    _axisController.jumpTo(
      target.clamp(0.0, position.maxScrollExtent),
    );
  }

  int _calculateIndex(Offset globalPosition) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return 0;
    final localOffset = box.globalToLocal(globalPosition);
    final row = timelineRowAt(
      localOffset.dy + _axisController.offset,
      rowExtent: AppSizes.gridRow,
      topPadding: AppSpacing.sm,
    );
    final column =
        (localOffset.dx / (box.size.width / 6)).floor().clamp(0, 5);
    return row * 6 + column;
  }

  void _handleTapDown(Offset globalPosition) {
    final index = _calculateIndex(globalPosition);
    setState(() {
      if (_selectionStart == index && _selectionEnd == index) {
        _selectionStart = null;
        _selectionEnd = null;
      } else {
        _selectionSerial++;
        _selectionStart = index;
        _selectionEnd = index;
      }
    });
  }

  void _handlePanStart(Offset globalPosition) {
    final index = _calculateIndex(globalPosition);
    setState(() {
      _selectionSerial++;
      _selectionStart = index;
      _selectionEnd = index;
    });
  }

  void _handlePanUpdate(Offset globalPosition) {
    final index = _calculateIndex(globalPosition);
    if (index == _selectionEnd) return;
    setState(() => _selectionEnd = index);
  }

  void _forwardPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_axisController.hasClients) return;
    final position = _axisController.position;
    final target = (_axisController.offset + event.scrollDelta.dy)
        .clamp(0.0, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.5) return;
    _axisController.jumpTo(target);
  }

  void _clearSelection() {
    setState(() {
      _selectionStart = null;
      _selectionEnd = null;
    });
  }

  void _openMainWindow() {
    context.read<MenuBarProvider?>()?.openMainWindow();
  }

  void _openSettings() {
    context.read<MenuBarProvider?>()?.openSettings();
  }

  void _quit() {
    context.read<MenuBarProvider?>()?.requestQuit();
  }

  void _write(TimeProvider provider, Category category, String? subLabel) {
    // 用户已经开始新的拖选：旧转盘的延迟写入直接丢弃，避免写到错误的范围。
    if (_pointerDown) return;
    final start = _selectionStart;
    final end = _selectionEnd;
    if (start == null || end == null) return;
    final blocked = provider.scheduleEditBlockedReason;
    if (blocked != null) {
      showAppSnackBar(context, blocked);
      return;
    }
    final from = math.min(start, end);
    final to = math.max(start, end);
    final date = DateTime(_now.year, _now.month, _now.day);
    final dateKey = provider.dateKeyFor(date);
    provider.assignCategoryToSlots(
      <int>{for (var index = from; index <= to; index++) index},
      category,
      subLabel: subLabel,
      date: date,
    );
    final version = provider.editVersionOn(dateKey);
    final label = subLabel ?? category.name;
    final range = formatMenuBarRange(from * 10, (to + 1) * 10);
    _clearSelection();

    // 记住这次目标；写偏好失败只影响下次默认位置，不影响已写入的时间块。
    final target = MenuBarTarget(
      categoryId: category.id,
      categoryName: category.name,
      subLabel: subLabel,
    );
    _rememberedTarget = target;
    unawaited(_targetStore.save(target));

    showAppUndoSnackBar(
      context,
      message: '已记录 $range $label',
      identityToken: AppIdentityService.identityStamp,
      onUndo: () async {
        if (!provider.undoLastChangeOnDate(dateKey, expectedVersion: version)) {
          throw StateError('已有新的修改，撤销已失效');
        }
      },
    );
  }

  Widget _buildTimeLabelRow(BuildContext context, int hour) {
    return Container(
      height: AppSizes.gridRow,
      alignment: Alignment.center,
      child: Text(
        '${hour.toString().padLeft(2, '0')}:00',
        style: AppText.gridLabel.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildRecordGrid(BuildContext context, DateTime today, bool canEdit) {
    // 桌面主题默认给纵向列表常显滚动条；这里显式关掉，否则时间轴
    // 自己的条和显式 Scrollbar 会在两侧各画一条。滚动仍然可用。
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Row(
        key: const ValueKey('menu-bar-time-grid'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: AppSizes.gridTimeAxis,
            child: ListView.builder(
              controller: _axisController,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              itemCount: 24,
              itemExtent: AppSizes.gridRow,
              itemBuilder: (context, hour) => _buildTimeLabelRow(context, hour),
            ),
          ),
          Expanded(
            child: Listener(
              onPointerSignal: _forwardPointerSignal,
              onPointerDown: (_) {
                if (!_pointerDown) setState(() => _pointerDown = true);
              },
              onPointerUp: (_) {
                if (_pointerDown) setState(() => _pointerDown = false);
              },
              onPointerCancel: (_) {
                if (_pointerDown) setState(() => _pointerDown = false);
              },
              child: TimeGrid(
                gridKey: _gridKey,
                date: today,
                clock: () => _now,
                controller: _gridController,
                dragStartIndex: _selectionStart,
                dragEndIndex: _selectionEnd,
                onTapDown: _handleTapDown,
                onPanStart: _handlePanStart,
                onPanUpdate: _handlePanUpdate,
                onRemoveSlot: (_) {
                  // 面板里不做删除；删除仍回主界面。
                },
                readOnly: !canEdit,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 允许宿主没有注册 TimeProvider（部分测试/启动失败页）：按空数据渲染。
    final provider = context.watch<TimeProvider?>();
    final today = DateTime(_now.year, _now.month, _now.day);
    final categories = provider?.categories ?? const <Category>[];
    final summary = buildMenuBarSummary(
      slots: provider?.slotsForDate(today) ?? const [],
      now: _now,
      categories: categories,
    );
    final blocked = provider?.scheduleEditBlockedReason;
    final loading = provider == null || !provider.isInitialLoadFinished;
    final dialVisible =
        !loading && blocked == null && _hasSelection && !_pointerDown;

    final grid = loading
        ? const Center(child: CircularProgressIndicator())
        : _buildRecordGrid(context, today, blocked == null);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          context.read<MenuBarProvider?>()?.hidePanel();
        },
      },
      child: Focus(
        autofocus: true,
        child: MenuBarPanelView(
          summary: summary,
          now: _now,
          selectionStart: _selectionStart,
          selectionEnd: _selectionEnd,
          blockedReason: blocked,
          grid: grid,
          dial: _DialSlot(
            visible: dialVisible,
            childBuilder: (context) => MenuBarTargetDial(
              key: ValueKey<String>('menu-bar-dial-$_selectionSerial'),
              categories: categories,
              initialTarget: _rememberedTarget,
              enabled: blocked == null,
              onWrite: (category, subLabel) =>
                  _write(provider!, category, subLabel),
            ),
            onExpanded: _ensureSelectionVisible,
          ),
          onOpenMainWindow: _openMainWindow,
          onOpenSettings: _openSettings,
          onQuit: _quit,
          onClearSelection: _clearSelection,
        ),
      ),
    );
  }
}

/// 底部转盘槽位：从 0 高度展开/收起，收起动画结束后才销毁子组件。
///
/// 不用 AnimatedSize：子组件被替换成 shrink 后内容会先消失、高度再慢慢缩。
class _DialSlot extends StatefulWidget {
  const _DialSlot({
    required this.visible,
    required this.childBuilder,
    this.onExpanded,
  });

  final bool visible;
  final WidgetBuilder childBuilder;
  final VoidCallback? onExpanded;

  @override
  State<_DialSlot> createState() => _DialSlotState();
}

class _DialSlotState extends State<_DialSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Widget? _child;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.transition,
    );
    if (widget.visible) {
      _child = widget.childBuilder(context);
      _controller.value = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onExpanded?.call();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = appMotionDuration(context);
  }

  @override
  void didUpdateWidget(covariant _DialSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      _child = widget.childBuilder(context);
      _controller.forward(from: 0).whenComplete(() {
        if (mounted) widget.onExpanded?.call();
      });
    } else if (!widget.visible && oldWidget.visible) {
      _controller.reverse().whenComplete(() {
        if (mounted && !widget.visible) {
          setState(() => _child = null);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: _controller, curve: AppMotion.curve),
      alignment: Alignment.topCenter,
      child: _child == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: _child,
            ),
    );
  }
}

/// 纯入参的面板视图：网格与转盘槽位由调用方注入，方便测试外壳与交互。
class MenuBarPanelView extends StatelessWidget {
  const MenuBarPanelView({
    super.key,
    required this.summary,
    required this.now,
    required this.grid,
    this.dial,
    this.selectionStart,
    this.selectionEnd,
    this.blockedReason,
    this.onOpenMainWindow,
    this.onOpenSettings,
    this.onQuit,
    this.onClearSelection,
  });

  final MenuBarSummary summary;
  final DateTime now;
  final Widget grid;
  final Widget? dial;
  final int? selectionStart;
  final int? selectionEnd;
  final String? blockedReason;
  final VoidCallback? onOpenMainWindow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onQuit;
  final VoidCallback? onClearSelection;

  static const List<String> _weekdayLabels = <String>[
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '日',
  ];

  bool get _hasSelection => selectionStart != null && selectionEnd != null;

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    // 用 Scaffold 而不是 Material：撤销提示条要挂在面板自己的 Scaffold 上，
    // 否则会落到被 Offstage 隐藏的主界面里，用户看不到。
    return Scaffold(
      backgroundColor: context.wallpaperFill(surfaces.panel),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context),
              const SizedBox(height: AppSpacing.xs),
              _buildHint(context),
              const SizedBox(height: AppSpacing.xs),
              Expanded(child: grid),
              if (dial != null) dial!,
              const SizedBox(height: AppSpacing.sm),
              Divider(height: AppSizes.hairline),
              _buildFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${now.month}月${now.day}日 周${_weekdayLabels[now.weekday - 1]}',
          style: AppText.sectionTitle,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '今日已记录 ${formatMenuBarDuration(summary.recordedMinutes)}',
          style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildHint(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (blockedReason != null) {
      return Text(
        blockedReason!,
        style: AppText.caption.copyWith(color: scheme.error),
      );
    }
    if (_hasSelection) {
      return Row(
        children: [
          Expanded(
            child: Text(
              '已选 ${formatMenuBarRange(selectionStart! * 10, (selectionEnd! + 1) * 10)} · 滚轮选事件，停下即记录',
              style: AppText.caption.copyWith(color: scheme.primary),
            ),
          ),
          if (onClearSelection != null)
            TextButton(
              onPressed: onClearSelection,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('清除'),
            ),
        ],
      );
    }
    return Text(
      '在格子上拖选一段（或点一格），松手后拨动事件',
      style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: onOpenMainWindow,
              icon: const Icon(Icons.open_in_full, size: AppSizes.appBarActionIcon),
              label: const Text('打开主窗口'),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          IconButton(
            tooltip: '设置',
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: '退出时间块',
            onPressed: onQuit,
            icon: const Icon(Icons.power_settings_new),
          ),
        ],
      ),
    );
  }
}