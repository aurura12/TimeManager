import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/category.dart';
import '../models/time_slot.dart';
import '../providers/menu_bar_provider.dart';
import '../providers/time_provider.dart';
import '../services/app_identity_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/app_snack_bar.dart';
import '../utils/menu_bar_summary.dart';
import 'menu_bar_event_editor.dart';

/// 菜单栏点开后的小面板：一整天的格子 + 分类目标。
///
/// 交互与记录页一致：在格子上拖选一段时间（或点一格），再点下方分类写入。
/// 一次选择 = 一次写入 = 一条撤销；格子按 24 行 × 6 列排布，整天的
/// 分布一屏可见，不用再滚动找时间。
class MenuBarPanel extends StatefulWidget {
  const MenuBarPanel({super.key, this.onOpenRecordAtDate});

  /// 详情里「在主窗口中查看」用。
  final ValueChanged<DateTime>? onOpenRecordAtDate;

  @override
  State<MenuBarPanel> createState() => _MenuBarPanelState();
}

class _MenuBarPanelState extends State<MenuBarPanel> {
  Timer? _clock;
  DateTime _now = DateTime.now();
  int? _selectionStart;
  int? _selectionEnd;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _hidePanel() {
    context.read<MenuBarProvider?>()?.hidePanel();
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

  void _selectRange(int start, int end) {
    setState(() {
      _selectionStart = math.min(start, end);
      _selectionEnd = math.max(start, end);
    });
  }

  void _clearSelection() {
    setState(() {
      _selectionStart = null;
      _selectionEnd = null;
    });
  }

  void _openSpan(MenuBarSpan span) {
    final today = DateTime.now();
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadius.rCard),
      ),
      builder: (sheetContext) => _SpanDetailSheet(
        span: span,
        onOpenRecord: widget.onOpenRecordAtDate == null
            ? null
            : () {
                Navigator.of(sheetContext).pop();
                _openMainWindow();
                widget.onOpenRecordAtDate?.call(
                  DateTime(today.year, today.month, today.day),
                );
              },
      ),
    );
  }

  Future<void> _addEvent(TimeProvider provider) async {
    final saved = await showMenuBarEventEditor(
      context,
      provider: provider,
      date: DateTime.now(),
    );
    if (!mounted || !saved) return;
    setState(() => _now = DateTime.now());
  }

  void _write(TimeProvider provider, Category category, String? subLabel) {
    final start = _selectionStart;
    final end = _selectionEnd;
    if (start == null || end == null) {
      showAppSnackBar(context, '先在时间轴上拖选一段');
      return;
    }
    final blocked = provider.scheduleEditBlockedReason;
    if (blocked != null) {
      showAppSnackBar(context, blocked);
      return;
    }
    final date = DateTime(_now.year, _now.month, _now.day);
    final dateKey = provider.dateKeyFor(date);
    provider.assignCategoryToSlots(
      <int>{for (var index = start; index <= end; index++) index},
      category,
      subLabel: subLabel,
      date: date,
    );
    final version = provider.editVersionOn(dateKey);
    final label = subLabel ?? category.name;
    final range = formatMenuBarRange(start * 10, (end + 1) * 10);
    _clearSelection();
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

  @override
  Widget build(BuildContext context) {
    // 允许宿主没有注册 TimeProvider（部分测试/启动失败页）：按空数据渲染。
    final provider = context.watch<TimeProvider?>();
    final today = DateTime(_now.year, _now.month, _now.day);
    final categories = provider?.categories ?? const <Category>[];
    final summary = buildMenuBarSummary(
      slots: provider?.slotsForDate(today) ?? const <TimeSlot>[],
      now: _now,
      categories: categories,
    );
    final blocked = provider?.scheduleEditBlockedReason;
    final loading = provider == null || !provider.isInitialLoadFinished;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _hidePanel,
      },
      child: Focus(
        autofocus: true,
        child: MenuBarPanelView(
          summary: summary,
          now: _now,
          loading: loading,
          categories: categories,
          selectionStart: _selectionStart,
          selectionEnd: _selectionEnd,
          blockedReason: blocked,
          canEdit: !loading && blocked == null,
          onOpenMainWindow: _openMainWindow,
          onOpenSettings: _openSettings,
          onQuit: _quit,
          onOpenSpan: _openSpan,
          onSelectRange: _selectRange,
          onClearSelection: _clearSelection,
          onWriteTarget: provider == null
              ? null
              : (category, subLabel) => _write(provider, category, subLabel),
          onPreciseAdd: provider == null ? null : () => _addEvent(provider),
        ),
      ),
    );
  }
}

/// 纯入参的面板视图，方便在 400×700 的测试视口里直接泵。
class MenuBarPanelView extends StatelessWidget {
  const MenuBarPanelView({
    super.key,
    required this.summary,
    required this.now,
    required this.loading,
    required this.categories,
    this.selectionStart,
    this.selectionEnd,
    this.blockedReason,
    this.canEdit = false,
    this.onOpenMainWindow,
    this.onOpenSettings,
    this.onQuit,
    this.onOpenSpan,
    this.onSelectRange,
    this.onClearSelection,
    this.onWriteTarget,
    this.onPreciseAdd,
  });

  final MenuBarSummary summary;
  final DateTime now;
  final bool loading;
  final List<Category> categories;
  final int? selectionStart;
  final int? selectionEnd;
  final String? blockedReason;
  final bool canEdit;
  final VoidCallback? onOpenMainWindow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onQuit;
  final ValueChanged<MenuBarSpan>? onOpenSpan;
  final void Function(int start, int end)? onSelectRange;
  final VoidCallback? onClearSelection;
  final void Function(Category category, String? subLabel)? onWriteTarget;
  final VoidCallback? onPreciseAdd;

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
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : MenuBarTimeGrid(
                        key: const ValueKey('menu-bar-time-grid'),
                        summary: summary,
                        now: now,
                        selectionStart: selectionStart,
                        selectionEnd: selectionEnd,
                        enabled: canEdit,
                        onTapSpan: onOpenSpan,
                        onSelectRange: onSelectRange,
                      ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildCategoryTargets(context),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
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
          ),
        ),
        if (onPreciseAdd != null)
          IconButton(
            tooltip: '精细添加（名称 / 精确起止）',
            onPressed: canEdit ? onPreciseAdd : null,
            icon: const Icon(Icons.add),
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
              '已选 ${formatMenuBarRange(selectionStart! * 10, (selectionEnd! + 1) * 10)} · 点分类写入',
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
      '在时间轴上拖选一段（或点一格），再点分类',
      style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
    );
  }

  Widget _buildCategoryTargets(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (categories.isEmpty) {
      return Text(
        '还没有分类，请先在主窗口里添加',
        style: AppText.caption.copyWith(color: scheme.error),
      );
    }
    final targets = <({Category category, String? subLabel})>[
      for (final category in categories) ...[
        (category: category, subLabel: null),
        for (final sub in category.subCategories)
          (category: category, subLabel: sub),
      ],
    ];
    return SizedBox(
      height: AppSizes.chip,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: targets.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final target = targets[index];
          return ActionChip(
            avatar: CircleAvatar(
              backgroundColor: target.category.color,
              radius: AppSizes.statusDot,
            ),
            label: Text(target.subLabel ?? target.category.name),
            onPressed: canEdit && onWriteTarget != null
                ? () => onWriteTarget!(target.category, target.subLabel)
                : null,
          );
        },
      ),
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

/// 24 行 × 6 列的全天格子：一行一小时、一格 10 分钟。
///
/// 高度自适应可用空间，所以不管面板多高都能一屏看完全天。鼠标拖拽
/// 划选、点一格单选；有记录的位置点开详情。绘制用 CustomPaint，
/// 144 个格子不会产生 144 个 widget。
class MenuBarTimeGrid extends StatefulWidget {
  const MenuBarTimeGrid({
    super.key,
    required this.summary,
    required this.now,
    this.selectionStart,
    this.selectionEnd,
    this.enabled = false,
    this.onTapSpan,
    this.onSelectRange,
  });

  final MenuBarSummary summary;
  final DateTime now;
  final int? selectionStart;
  final int? selectionEnd;
  final bool enabled;
  final ValueChanged<MenuBarSpan>? onTapSpan;
  final void Function(int start, int end)? onSelectRange;

  static const double gutterWidth = 22;
  static const int slotCount = 144;

  @override
  State<MenuBarTimeGrid> createState() => _MenuBarTimeGridState();
}

class _MenuBarTimeGridState extends State<MenuBarTimeGrid> {
  int? _dragStart;
  int? _dragEnd;

  bool get _hasSelection =>
      widget.selectionStart != null && widget.selectionEnd != null;

  int _indexAt(Offset position, double cellWidth, double rowHeight) {
    final column = ((position.dx - MenuBarTimeGrid.gutterWidth) / cellWidth)
        .floor()
        .clamp(0, 5);
    final row = (position.dy / rowHeight).floor().clamp(0, 23);
    return row * 6 + column;
  }

  MenuBarSpan? _spanAt(int index) {
    final minute = index * 10;
    for (final span in widget.summary.spans) {
      if (span.containsMinute(minute)) return span;
    }
    return null;
  }

  void _start(Offset position, double cellWidth, double rowHeight) {
    final index = _indexAt(position, cellWidth, rowHeight);
    setState(() {
      _dragStart = index;
      _dragEnd = index;
    });
  }

  void _extend(Offset position, double cellWidth, double rowHeight) {
    if (_dragStart == null) return;
    final index = _indexAt(position, cellWidth, rowHeight);
    if (index == _dragEnd) return;
    setState(() => _dragEnd = index);
  }

  void _finish() {
    final start = _dragStart;
    final end = _dragEnd;
    setState(() {
      _dragStart = null;
      _dragEnd = null;
    });
    if (start == null || end == null) return;
    widget.onSelectRange?.call(math.min(start, end), math.max(start, end));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surfaces.subtle,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final rowHeight = height / 24;
            final cellWidth = (width - MenuBarTimeGrid.gutterWidth) / 6;

            final dragStart = _dragStart;
            final dragEnd = _dragEnd;
            final previewStart =
                dragStart == null || dragEnd == null ? null : math.min(dragStart, dragEnd);
            final previewEnd =
                dragStart == null || dragEnd == null ? null : math.max(dragStart, dragEnd);

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: !widget.enabled
                  ? null
                  : (details) {
                      final index = _indexAt(
                        details.localPosition,
                        cellWidth,
                        rowHeight,
                      );
                      final span = _spanAt(index);
                      if (span != null) {
                        widget.onTapSpan?.call(span);
                        return;
                      }
                      widget.onSelectRange?.call(index, index);
                    },
              onPanStart: widget.enabled
                  ? (details) => _start(
                        details.localPosition,
                        cellWidth,
                        rowHeight,
                      )
                  : null,
              onPanUpdate: widget.enabled
                  ? (details) => _extend(
                        details.localPosition,
                        cellWidth,
                        rowHeight,
                      )
                  : null,
              onPanEnd: widget.enabled ? (_) => _finish() : null,
              onPanCancel: widget.enabled
                  ? () => setState(() {
                        _dragStart = null;
                        _dragEnd = null;
                      })
                  : null,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _MenuBarGridPainter(
                        summary: widget.summary,
                        now: widget.now,
                        cellWidth: cellWidth,
                        rowHeight: rowHeight,
                        gutter: MenuBarTimeGrid.gutterWidth,
                        lineColor: scheme.outlineVariant.withValues(alpha: 0.45),
                        primaryColor: scheme.primary,
                        selectionStart: previewStart ?? widget.selectionStart,
                        selectionEnd: previewEnd ?? widget.selectionEnd,
                        showSelection: previewStart != null || _hasSelection,
                      ),
                    ),
                  ),
                  for (var hour = 0; hour < 24; hour += 2)
                    Positioned(
                      top: hour * rowHeight - 6,
                      left: 0,
                      width: MenuBarTimeGrid.gutterWidth - 6,
                      child: Text(
                        hour.toString().padLeft(2, '0'),
                        textAlign: TextAlign.right,
                        style: AppText.caption.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MenuBarGridPainter extends CustomPainter {
  _MenuBarGridPainter({
    required this.summary,
    required this.now,
    required this.cellWidth,
    required this.rowHeight,
    required this.gutter,
    required this.lineColor,
    required this.primaryColor,
    required this.selectionStart,
    required this.selectionEnd,
    required this.showSelection,
  });

  final MenuBarSummary summary;
  final DateTime now;
  final double cellWidth;
  final double rowHeight;
  final double gutter;
  final Color lineColor;
  final Color primaryColor;
  final int? selectionStart;
  final int? selectionEnd;
  final bool showSelection;

  Rect _rectForMinute(int minute) {
    final row = minute ~/ 60;
    final column = (minute % 60) ~/ 10;
    return Rect.fromLTWH(
      gutter + column * cellWidth + 0.5,
      row * rowHeight + 0.5,
      cellWidth - 1,
      rowHeight - 1,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    for (var hour = 1; hour < 24; hour++) {
      final y = hour * rowHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
    for (var column = 0; column <= 6; column++) {
      final x = gutter + column * cellWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }

    final radius = Radius.circular(AppRadius.grid);
    for (final span in summary.spans) {
      final paint = Paint()..color = span.color ?? primaryColor;
      for (var minute = span.startMinute;
          minute < span.endMinute;
          minute += 10) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(_rectForMinute(minute), radius),
          paint,
        );
      }
    }

    if (showSelection && selectionStart != null && selectionEnd != null) {
      final fill = Paint()..color = primaryColor.withValues(alpha: 0.22);
      final border = Paint()
        ..color = primaryColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (var index = selectionStart!; index <= selectionEnd!; index++) {
        final rect = _rectForMinute(index * 10);
        final rrect = RRect.fromRectAndRadius(rect, radius);
        canvas.drawRRect(rrect, fill);
        canvas.drawRRect(rrect, border);
      }
    }

    final nowMinute = now.hour * 60 + now.minute;
    final nowY = (nowMinute / 60) * rowHeight;
    canvas.drawLine(
      Offset(0, nowY),
      Offset(size.width, nowY),
      Paint()
        ..color = primaryColor
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _MenuBarGridPainter oldDelegate) {
    return oldDelegate.summary != summary ||
        oldDelegate.now != now ||
        oldDelegate.selectionStart != selectionStart ||
        oldDelegate.selectionEnd != selectionEnd ||
        oldDelegate.showSelection != showSelection ||
        oldDelegate.cellWidth != cellWidth ||
        oldDelegate.rowHeight != rowHeight ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.primaryColor != primaryColor;
  }
}

class _SpanDetailSheet extends StatelessWidget {
  const _SpanDetailSheet({required this.span, this.onOpenRecord});

  final MenuBarSpan span;
  final VoidCallback? onOpenRecord;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: AppSpacing.sheet,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: AppSizes.statusDot,
                height: AppSizes.statusDot,
                decoration: BoxDecoration(
                  color: span.color ?? scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  span.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.sectionTitle,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _DetailRow(
            label: '时间',
            value: formatMenuBarRange(span.startMinute, span.endMinute),
          ),
          _DetailRow(label: '时长', value: formatMenuBarDuration(span.minutes)),
          if (span.isFromCalendar)
            const _DetailRow(label: '来源', value: 'Google 日历'),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
              if (onOpenRecord != null) ...[
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: onOpenRecord,
                  child: const Text('在主窗口中查看'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: AppSizes.gridTimeAxis,
            child: Text(
              label,
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value, style: AppText.body)),
        ],
      ),
    );
  }
}