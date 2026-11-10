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
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/app_snack_bar.dart';
import '../utils/menu_bar_summary.dart';
import 'menu_bar_event_editor.dart';

/// 菜单栏点开后的小面板：今日速览 + 可以直接刷格子的迷你时间轴。
///
/// 交互刻意贴近主界面：先在底部选分类，再在时间轴上点一格或拖一段，
/// 松手即写入（一次手势 = 一条撤销记录）。已有时间块点开是只读详情，
/// 拖过它们会直接覆盖，与记录页刷格子一致。
class MenuBarPanel extends StatefulWidget {
  const MenuBarPanel({super.key, this.onOpenRecordAtDate});

  /// 详情里「在主窗口中查看」用。
  final ValueChanged<DateTime>? onOpenRecordAtDate;

  /// 同一个进程内记住上次用的分类，避免每次打开面板都要重选。
  static String? _lastCategoryId;

  @override
  State<MenuBarPanel> createState() => _MenuBarPanelState();
}

class _MenuBarPanelState extends State<MenuBarPanel> {
  Timer? _clock;
  DateTime _now = DateTime.now();
  String? _categoryId = MenuBarPanel._lastCategoryId;
  String? _subLabel;

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

  Category? _resolveCategory(List<Category> categories) {
    for (final category in categories) {
      if (category.id == _categoryId) return category;
    }
    return null;
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

  void _selectCategory(Category category) {
    setState(() {
      _categoryId = category.id;
      _subLabel = null;
      MenuBarPanel._lastCategoryId = category.id;
    });
  }

  void _handleTapCell(
    TimeProvider provider,
    MenuBarSummary summary,
    int index,
  ) {
    final minute = index * 10;
    for (final span in summary.spans) {
      if (span.containsMinute(minute)) {
        _openSpan(span);
        return;
      }
    }
    final category = _resolveCategory(provider.categories);
    if (category == null) {
      showAppSnackBar(context, '先在下面选一个分类');
      return;
    }
    _paint(provider, category, index, index);
  }

  void _paint(
    TimeProvider provider,
    Category category,
    int startIndex,
    int endIndex,
  ) {
    final blocked = provider.scheduleEditBlockedReason;
    if (blocked != null) {
      showAppSnackBar(context, blocked);
      return;
    }
    final indices = <int>{
      for (var index = startIndex; index <= endIndex; index++) index,
    };
    if (indices.isEmpty) return;
    final date = DateTime(_now.year, _now.month, _now.day);
    final dateKey = provider.dateKeyFor(date);
    provider.assignCategoryToSlots(
      indices,
      category,
      subLabel: _subLabel,
      date: date,
    );
    final version = provider.editVersionOn(dateKey);
    final label = _subLabel ?? category.name;
    final range = formatMenuBarRange(startIndex * 10, (endIndex + 1) * 10);
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
    final selected = _resolveCategory(categories);
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
          selectedCategoryId: selected?.id,
          selectedSubLabel: _subLabel,
          blockedReason: blocked,
          canEdit: !loading && blocked == null,
          onOpenMainWindow: _openMainWindow,
          onOpenSettings: _openSettings,
          onQuit: _quit,
          onOpenSpan: _openSpan,
          onSelectCategory: _selectCategory,
          onSelectSubLabel: (value) => setState(() => _subLabel = value),
          onTapCell: provider == null
              ? null
              : (index) => _handleTapCell(provider, summary, index),
          onPaintRange: provider == null
              ? null
              : (start, end) {
                  final category = _resolveCategory(provider.categories);
                  if (category == null) {
                    showAppSnackBar(context, '先在下面选一个分类');
                    return;
                  }
                  _paint(provider, category, start, end);
                },
          onPreciseAdd: provider == null ? null : () => _addEvent(provider),
        ),
      ),
    );
  }
}

/// 纯入参的面板视图，方便在 400×560 的测试视口里直接泵。
class MenuBarPanelView extends StatelessWidget {
  const MenuBarPanelView({
    super.key,
    required this.summary,
    required this.now,
    required this.loading,
    required this.categories,
    this.selectedCategoryId,
    this.selectedSubLabel,
    this.blockedReason,
    this.canEdit = false,
    this.onOpenMainWindow,
    this.onOpenSettings,
    this.onQuit,
    this.onOpenSpan,
    this.onSelectCategory,
    this.onSelectSubLabel,
    this.onTapCell,
    this.onPaintRange,
    this.onPreciseAdd,
  });

  final MenuBarSummary summary;
  final DateTime now;
  final bool loading;
  final List<Category> categories;
  final String? selectedCategoryId;
  final String? selectedSubLabel;
  final String? blockedReason;
  final bool canEdit;
  final VoidCallback? onOpenMainWindow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onQuit;
  final ValueChanged<MenuBarSpan>? onOpenSpan;
  final ValueChanged<Category>? onSelectCategory;
  final ValueChanged<String>? onSelectSubLabel;
  final ValueChanged<int>? onTapCell;
  final void Function(int start, int end)? onPaintRange;
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

  Category? get _selectedCategory {
    for (final category in categories) {
      if (category.id == selectedCategoryId) return category;
    }
    return null;
  }

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
              Text(
                canEdit
                    ? '选分类后拖动时间轴记录，点已有块看详情'
                    : (blockedReason ?? '日程还没准备好'),
                style: AppText.caption.copyWith(
                  color: blockedReason == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : MenuBarTimeGrid(
                        key: const ValueKey('menu-bar-time-grid'),
                        summary: summary,
                        now: now,
                        enabled: canEdit,
                        onTapCell: onTapCell,
                        onPaintRange: onPaintRange,
                      ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildCategoryStrip(context),
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

  Widget _buildCategoryStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedCategory;
    if (categories.isEmpty) {
      return Text(
        '还没有分类，请先在主窗口里添加',
        style: AppText.caption.copyWith(color: scheme.error),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: AppSizes.chip,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) {
              final category = categories[index];
              final isSelected = category.id == selected?.id;
              return ChoiceChip(
                selected: isSelected,
                avatar: CircleAvatar(
                  backgroundColor: category.color,
                  radius: AppSizes.statusDot,
                ),
                label: Text(category.name),
                onSelected: canEdit && onSelectCategory != null
                    ? (_) => onSelectCategory!(category)
                    : null,
              );
            },
          ),
        ),
        if (selected != null && selected.subCategories.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            height: AppSizes.chip,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: selected.subCategories.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, index) {
                final sub = selected.subCategories[index];
                return ChoiceChip(
                  selected: selectedSubLabel == sub,
                  label: Text(sub),
                  onSelected: canEdit && onSelectSubLabel != null
                      ? (_) => onSelectSubLabel!(sub)
                      : null,
                );
              },
            ),
          ),
        ],
      ],
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

/// 迷你时间轴：10 分钟一格，60px/小时，鼠标滚轮滚动，鼠标拖拽刷格子。
class MenuBarTimeGrid extends StatefulWidget {
  const MenuBarTimeGrid({
    super.key,
    required this.summary,
    required this.now,
    required this.enabled,
    this.onTapCell,
    this.onPaintRange,
  });

  final MenuBarSummary summary;
  final DateTime now;
  final bool enabled;
  final ValueChanged<int>? onTapCell;
  final void Function(int start, int end)? onPaintRange;

  static const double pxPerMinute = 1;
  static const double gutterWidth = 40;
  static const int slotCount = 144;

  @override
  State<MenuBarTimeGrid> createState() => _MenuBarTimeGridState();
}

class _MenuBarTimeGridState extends State<MenuBarTimeGrid> {
  late final ScrollController _scrollController;
  int? _dragStart;
  int? _dragEnd;

  static const double _contentHeight =
      MenuBarTimeGrid.slotCount * 10 * MenuBarTimeGrid.pxPerMinute;

  @override
  void initState() {
    super.initState();
    final nowMinute = widget.now.hour * 60 + widget.now.minute;
    final offset = (nowMinute - 120).clamp(0, _contentHeight - 360).toDouble();
    _scrollController = ScrollController(initialScrollOffset: offset);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  int _indexAt(double dy) {
    final index = (dy / MenuBarTimeGrid.pxPerMinute / 10).floor();
    return index.clamp(0, MenuBarTimeGrid.slotCount - 1);
  }

  void _start(Offset localPosition) {
    final index = _indexAt(localPosition.dy);
    setState(() {
      _dragStart = index;
      _dragEnd = index;
    });
  }

  void _extend(Offset localPosition) {
    if (_dragStart == null) return;
    final index = _indexAt(localPosition.dy);
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
    widget.onPaintRange?.call(math.min(start, end), math.max(start, end));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final nowMinute = widget.now.hour * 60 + widget.now.minute;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surfaces.subtle,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Scrollbar(
          controller: _scrollController,
          child: SingleChildScrollView(
            controller: _scrollController,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: widget.enabled && widget.onTapCell != null
                  ? (details) => widget.onTapCell!(
                        _indexAt(details.localPosition.dy),
                      )
                  : null,
              onPanStart:
                  widget.enabled ? (details) => _start(details.localPosition) : null,
              onPanUpdate: widget.enabled
                  ? (details) => _extend(details.localPosition)
                  : null,
              onPanEnd: widget.enabled ? (_) => _finish() : null,
              onPanCancel: widget.enabled
                  ? () => setState(() {
                        _dragStart = null;
                        _dragEnd = null;
                      })
                  : null,
              child: SizedBox(
                height: _contentHeight,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final dragStart = _dragStart;
                    final dragEnd = _dragEnd;
                    final selectionStart =
                        dragStart == null || dragEnd == null
                            ? null
                            : math.min(dragStart, dragEnd);
                    final selectionEnd =
                        dragStart == null || dragEnd == null
                            ? null
                            : math.max(dragStart, dragEnd);

                    return Stack(
                      children: [
                        for (var hour = 1; hour < 24; hour++)
                          Positioned(
                            top: hour * 60 * MenuBarTimeGrid.pxPerMinute,
                            left: 0,
                            right: 0,
                            height: AppSizes.hairline,
                            child: ColoredBox(
                              color: scheme.outlineVariant.withValues(alpha: 0.4),
                            ),
                          ),
                        for (var hour = 0; hour < 24; hour++)
                          Positioned(
                            top: hour * 60 * MenuBarTimeGrid.pxPerMinute - 7,
                            left: 0,
                            width: MenuBarTimeGrid.gutterWidth - 6,
                            child: Text(
                              '${hour.toString().padLeft(2, '0')}:00',
                              textAlign: TextAlign.right,
                              style: AppText.caption.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        for (final span in widget.summary.spans)
                          Positioned(
                            top: span.startMinute * MenuBarTimeGrid.pxPerMinute,
                            left: MenuBarTimeGrid.gutterWidth,
                            width: width -
                                MenuBarTimeGrid.gutterWidth -
                                AppSizes.statusDot,
                            height: math.max(
                              span.minutes * MenuBarTimeGrid.pxPerMinute,
                              AppSizes.statusDot,
                            ),
                            child: _buildSpan(context, span),
                          ),
                        if (selectionStart != null && selectionEnd != null)
                          Positioned(
                            top: selectionStart *
                                10 *
                                MenuBarTimeGrid.pxPerMinute,
                            left: MenuBarTimeGrid.gutterWidth,
                            width: width - MenuBarTimeGrid.gutterWidth - 8,
                            height: (selectionEnd - selectionStart + 1) *
                                10 *
                                MenuBarTimeGrid.pxPerMinute,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.22),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.grid),
                                border: Border.all(color: scheme.primary),
                              ),
                            ),
                          ),
                        Positioned(
                          top: nowMinute * MenuBarTimeGrid.pxPerMinute,
                          left: 0,
                          right: 0,
                          height: AppSizes.hairline * 1.5,
                          child: ColoredBox(color: scheme.primary),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSpan(BuildContext context, MenuBarSpan span) {
    final scheme = Theme.of(context).colorScheme;
    final color = span.color ?? scheme.primary;
    final showLabel = span.minutes >= 30;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.grid),
      ),
      child: showLabel
          ? Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: AppSpacing.xs / 2,
              ),
              child: Text(
                span.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.badge.copyWith(
                  color: AppSemanticColors.onColor(color),
                ),
              ),
            )
          : null,
    );
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