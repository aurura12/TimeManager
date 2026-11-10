import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
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
import '../utils/menu_bar_dial_position.dart';
import '../utils/menu_bar_summary.dart';
import '../utils/timeline_geometry.dart';
import 'menu_bar_target_dial.dart';
import 'time_grid.dart';

/// 菜单栏点开后的小面板：记录页同款时间网格 + 选时间后贴着选区弹出的双转盘。
///
/// 复用记录页的 [TimeGrid]（45px 行高、一小时一行、6 个 10 分钟格），
/// 选完时间段松手后在选区旁浮出「左右双竖转盘」：左分类、右子事件，
/// 滚轮转动、停下自动写入；点中间项可立即写入。浮层不占底部高度，
/// 所以网格始终是满视口高度，转盘一次能显示 7 行。
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

  /// 网格纵向偏移：转盘浮层按它跟随滚动，选中的那几行滚出视口后浮层自然隐藏。
  final ValueNotifier<double> _gridScrollOffset = ValueNotifier<double>(0);
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
    _gridScrollOffset.dispose();
    super.dispose();
  }

  void _syncGridScroll() {
    _gridScrollOffset.value = _axisController.offset;
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
    if ((position.pixels - target).abs() < 1) {
      // 已经在位也要同步一次：首帧浮层不能停在 0 上。
      _gridScrollOffset.value = position.pixels;
      return;
    }
    _axisController.jumpTo(target);
    _gridScrollOffset.value = target;
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
    _scrollAxisBy(event.scrollDelta.dy);
  }

  /// 触控板双指滑动（pan-zoom）转发：和滚轮一样推时间轴，
  /// 否则面板网格上滚不动，还会被当成拖选。
  void _forwardPanZoom(PointerPanZoomUpdateEvent event) {
    if (!_axisController.hasClients) return;
    _scrollAxisBy(-event.panDelta.dy);
  }

  void _scrollAxisBy(double dy) {
    final position = _axisController.position;
    final target =
        (_axisController.offset + dy).clamp(0.0, position.maxScrollExtent);
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
              onPointerPanZoomUpdate: _forwardPanZoom,
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
          gridScroll: _gridScrollOffset,
          dial: dialVisible
              ? MenuBarTargetDial(
                  key: ValueKey<String>('menu-bar-dial-$_selectionSerial'),
                  categories: categories,
                  initialTarget: _rememberedTarget,
                  enabled: blocked == null,
                  onWrite: (category, subLabel) =>
                      _write(provider, category, subLabel),
                )
              : null,
          onOpenMainWindow: _openMainWindow,
          onOpenSettings: _openSettings,
          onQuit: _quit,
          onClearSelection: _clearSelection,
        ),
      ),
    );
  }
}

/// 纯入参的面板视图：网格与转盘浮层由调用方注入，方便测试外壳与交互。
class MenuBarPanelView extends StatelessWidget {
  const MenuBarPanelView({
    super.key,
    required this.summary,
    required this.now,
    required this.grid,
    this.dial,
    this.gridScroll,
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

  /// 网格纵向偏移（面板 state 的滚动值）；浮层按它跟随滚动。
  final ValueListenable<double>? gridScroll;
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
              Expanded(child: _buildTimelineArea(context)),
              const SizedBox(height: AppSpacing.sm),
              Divider(height: AppSizes.hairline),
              _buildFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 网格区域：转盘浮层叠在网格上方，按选区锚定并跟随滚动。
  ///
  /// 浮层放在网格这层 Stack 里（而不是整个面板），"夹在可视区内" 由
  /// constraints 直接保证，不需要量 RenderBox；网格高度也不再因浮层变化。
  Widget _buildTimelineArea(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounds = constraints.biggest;

        Widget overlay(double scrollOffset) {
          final dialWidget = dial;
          final start = selectionStart;
          final end = selectionEnd;
          if (dialWidget == null || start == null || end == null) {
            return const SizedBox.shrink();
          }
          final selection = timelineSelectionRect(
            startIndex: start,
            endIndex: end,
            contentWidth: bounds.width,
            gridLeft: AppSizes.gridTimeAxis,
            scrollOffset: scrollOffset,
            rowExtent: AppSizes.gridRow,
            topPadding: AppSpacing.sm,
            cellInset: AppSizes.hairline,
          );
          if (!menuBarSelectionVisible(selection, bounds)) {
            return const SizedBox.shrink();
          }
          final placement = placeMenuBarDial(
            selection: selection,
            bounds: bounds,
            dialSize: const Size(
              AppSizes.dialOverlayWidth,
              AppSizes.dialOverlayHeight,
            ),
          );
          // 视口矮到连一行都放不下时宁可不画，避免压扁成一条细缝。
          if (placement.rect.height < AppSizes.dialRowHeight) {
            return const SizedBox.shrink();
          }
          return Positioned.fromRect(
            rect: placement.rect,
            child: _buildDialOverlay(context, dialWidget),
          );
        }

        final scroll = gridScroll;
        // 显式钉住尺寸：Column 是 start 对齐（宽度约束松散），Stack 全用
        // Positioned 子组件时不会被撑开，网格会拿到 0 宽。
        return SizedBox(
          width: bounds.width,
          height: bounds.height,
          child: Stack(
            children: [
              Positioned.fill(child: grid),
              if (scroll == null)
                overlay(0)
              else
                ValueListenableBuilder<double>(
                  valueListenable: scroll,
                  builder: (context, offset, _) => overlay(offset),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 浮层底：必须不透明（壁纸模式下也不能透），圆角裁掉子组件的直角。
  Widget _buildDialOverlay(BuildContext context, Widget child) {
    return Material(
      color: AppSurfaces.of(context).overlay,
      elevation: AppSizes.dialOverlayElevation,
      borderRadius: AppRadius.cardAll,
      clipBehavior: Clip.antiAlias,
      child: child,
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