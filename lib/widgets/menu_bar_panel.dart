import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/category.dart';
import '../models/time_slot.dart';
import '../providers/menu_bar_provider.dart';
import '../providers/time_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/menu_bar_summary.dart';
import 'menu_bar_event_editor.dart';

/// 菜单栏点开后的小面板：今日概览条 + 时间块列表。
///
/// 只读：点块看详情，新增日程走 [MenuBarEventEditor]（由面板头部按钮打开）。
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
    context.read<MenuBarProvider?>()?.quit();
  }

  Future<void> _addEvent() async {
    final provider = context.read<TimeProvider?>();
    if (provider == null) return;
    final saved = await showMenuBarEventEditor(
      context,
      provider: provider,
      date: DateTime.now(),
    );
    if (!mounted || !saved) return;
    setState(() => _now = DateTime.now());
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

  @override
  Widget build(BuildContext context) {
    // 允许宿主没有注册 TimeProvider（部分测试/启动失败页）：按空数据渲染。
    final provider = context.watch<TimeProvider?>();
    final today = DateTime(_now.year, _now.month, _now.day);
    final summary = buildMenuBarSummary(
      slots: provider?.slotsForDate(today) ?? const <TimeSlot>[],
      now: _now,
      categories: provider?.categories ?? const <Category>[],
    );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _hidePanel,
      },
      child: Focus(
        autofocus: true,
        child: MenuBarPanelView(
          summary: summary,
          now: _now,
          loading: provider == null || !provider.isInitialLoadFinished,
          onOpenMainWindow: _openMainWindow,
          onOpenSettings: _openSettings,
          onQuit: _quit,
          onSpanTap: _openSpan,
          onAdd: provider == null ? null : _addEvent,
          addBlockedReason: provider?.scheduleEditBlockedReason,
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
    this.onOpenMainWindow,
    this.onOpenSettings,
    this.onQuit,
    this.onSpanTap,
    this.onAdd,
    this.addBlockedReason,
  });

  final MenuBarSummary summary;
  final DateTime now;
  final bool loading;
  final VoidCallback? onOpenMainWindow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onQuit;
  final ValueChanged<MenuBarSpan>? onSpanTap;
  final VoidCallback? onAdd;

  /// 非空时新增入口禁用，并把原因作为提示显示。
  final String? addBlockedReason;

  static const List<String> _weekdayLabels = <String>[
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '日',
  ];

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
              const SizedBox(height: AppSpacing.md),
              _DayOverviewBar(summary: summary, now: now),
              const SizedBox(height: AppSpacing.sm),
              _buildHourTicks(context),
              const SizedBox(height: AppSpacing.sm),
              Divider(height: AppSizes.hairline),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildSpanList(context),
              ),
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
        if (onAdd != null)
          IconButton(
            tooltip: addBlockedReason ?? '新增日程',
            onPressed: addBlockedReason == null ? onAdd : null,
            icon: const Icon(Icons.add),
          ),
      ],
    );
  }

  Widget _buildHourTicks(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        for (final hour in const <int>[0, 6, 12, 18, 24])
          Text(
            '$hour',
            style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _buildSpanList(BuildContext context) {
    if (summary.spans.isEmpty) {
      return _buildEmptyState(context);
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      itemCount: summary.spans.length,
      itemBuilder: (context, index) {
        final span = summary.spans[index];
        return _SpanRow(
          span: span,
          onTap: onSpanTap == null ? null : () => onSpanTap!(span),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.event_note_outlined,
            size: AppSizes.iconButton,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('今天还没有记录', style: AppText.body),
          const SizedBox(height: AppSpacing.xs),
          Text(
            onAdd == null ? '点右上角「＋」补一段' : '点下方「补一段」记录刚才做过的事',
            style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (addBlockedReason != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              addBlockedReason!,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: scheme.error),
            ),
          ],
          if (onAdd != null) ...[
            const SizedBox(height: AppSpacing.md),
            TextButton.icon(
              onPressed: addBlockedReason == null ? onAdd : null,
              icon: const Icon(Icons.add),
              label: const Text('补一段'),
            ),
          ],
        ],
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

class _DayOverviewBar extends StatelessWidget {
  const _DayOverviewBar({required this.summary, required this.now});

  final MenuBarSummary summary;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final segments = buildMenuBarBarSegments(summary.spans);
    final nowFactor =
        (now.hour * 60 + now.minute) / menuBarMinutesPerDay;

    return SizedBox(
      height: 44,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: surfaces.subtle,
                    borderRadius: BorderRadius.circular(AppRadius.badge),
                  ),
                ),
              ),
              for (final segment in segments)
                Positioned(
                  left: segment.left * width,
                  width: math.max(segment.width * width, AppSizes.statusDot / 4),
                  top: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: segment.span.color ?? scheme.primary,
                      borderRadius: BorderRadius.circular(AppRadius.grid),
                    ),
                  ),
                ),
              Positioned(
                left: nowFactor * (width - AppSizes.hairline),
                top: -AppSpacing.xs,
                bottom: -AppSpacing.xs,
                width: AppSizes.hairline,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(AppRadius.grid),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SpanRow extends StatelessWidget {
  const _SpanRow({required this.span, this.onTap});

  final MenuBarSpan span;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.sm,
        ),
        child: Row(
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          span.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body,
                        ),
                      ),
                      if (span.isFromCalendar) ...[
                        const SizedBox(width: AppSpacing.xs),
                        Icon(
                          Icons.event_outlined,
                          size: AppSizes.statusDot + AppSpacing.xs,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    formatMenuBarRange(span.startMinute, span.endMinute),
                    style: AppText.caption.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              formatMenuBarDuration(span.minutes),
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
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
