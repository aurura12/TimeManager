import 'package:flutter/material.dart';

import '../models/target.dart';
import '../providers/time_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

enum _TargetAction { view, edit, delete }

/// 桌面目标行：详情、编辑、更多操作和拖拽把手各有明确入口。
class DesktopTargetCard extends StatelessWidget {
  const DesktopTargetCard({
    super.key,
    required this.target,
    required this.provider,
    required this.index,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final Target target;
  final TimeProvider provider;
  final int index;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  void _act(_TargetAction action) {
    switch (action) {
      case _TargetAction.view:
        onOpen();
      case _TargetAction.edit:
        onEdit();
      case _TargetAction.delete:
        onDelete();
    }
  }

  List<PopupMenuEntry<_TargetAction>> _menu() => const [
        PopupMenuItem(value: _TargetAction.view, child: Text('查看详情')),
        PopupMenuItem(value: _TargetAction.edit, child: Text('编辑目标')),
        PopupMenuDivider(),
        PopupMenuItem(value: _TargetAction.delete, child: Text('删除目标')),
      ];

  Future<void> _showContextMenu(
    BuildContext context,
    TapUpDetails details,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = overlay.globalToLocal(details.globalPosition);
    final action = await showMenu<_TargetAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _menu(),
    );
    if (context.mounted && action != null) _act(action);
  }

  String _number(double value) => value.toStringAsFixed(1).replaceAll('.0', '');

  String get _typeLabel => switch (target.type) {
        TargetType.duration => '时长目标',
        TargetType.frequency => '次数目标',
        TargetType.timePoint => '时间点目标',
      };

  String get _rule => switch (target.type) {
        TargetType.duration =>
          '${target.compareType} ${_number(target.durationHours)} 小时',
        TargetType.frequency =>
          '${target.compareType} ${target.frequencyCount} 次',
        TargetType.timePoint =>
          '${target.targetTime} ${target.compareType.contains('前') || target.compareType.contains('少') ? '之前' : '之后'}',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final metadata = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(target.name, style: AppText.sectionTitle),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '$_typeLabel · ${target.period} · $_rule',
          style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '编辑目标',
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
        PopupMenuButton<_TargetAction>(
          tooltip: '更多操作',
          onSelected: _act,
          itemBuilder: (_) => _menu(),
          icon: const Icon(Icons.more_horiz),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.rowGap),
      child: Card(
        margin: EdgeInsets.zero,
        color: context.wallpaperFill(surfaces.card),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.cardAll,
          side: BorderSide(color: surfaces.border),
        ),
        child: InkWell(
          onTap: onOpen,
          onSecondaryTapUp: (details) => _showContextMenu(context, details),
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: AppSpacing.card,
            child: LayoutBuilder(builder: (context, constraints) {
              final progress = _buildProgress(context);
              final wide =
                  constraints.maxWidth >= AppSizes.desktopTargetRowBreakpoint;
              return Row(
                children: [
                  Tooltip(
                    message: '拖动排序',
                    child: ReorderableDragStartListener(
                      index: index,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        hitTestBehavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          width: AppSizes.minTapTarget,
                          height: AppSizes.minTapTarget,
                          child: Icon(Icons.drag_indicator,
                              color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    width: AppSpacing.xs,
                    height: AppSizes.minTapTarget,
                    decoration: BoxDecoration(
                      color: context.adaptSemanticFill(target.color),
                      borderRadius: AppRadius.gridAll,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: wide
                        ? Row(children: [
                            Expanded(child: metadata),
                            const SizedBox(width: AppSpacing.xl),
                            SizedBox(
                              width: AppSizes.desktopTargetProgressWidth,
                              child: progress,
                            ),
                            const SizedBox(width: AppSpacing.md),
                            actions,
                          ])
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Expanded(child: metadata),
                                actions,
                              ]),
                              const SizedBox(height: AppSpacing.md),
                              progress,
                            ],
                          ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surface = AppSurfaces.of(context).card;
    String label;
    String valueText;
    Color statusColor;
    double? ratio;

    if (target.type == TargetType.timePoint) {
      final status = provider.getTimePointStatus(target, DateTime.now());
      (label, statusColor) = switch (status) {
        TimePointStatus.onTime => ('今日准时', AppSemanticColors.success),
        TimePointStatus.late => ('今日未达标', AppSemanticColors.warning),
        TimePointStatus.notDone => ('今日未记录', scheme.onSurfaceVariant),
      };
      valueText = '累计达标 ${provider.getTargetPersistenceDays(target)} 天';
    } else {
      final current = provider.calculateTargetProgress(target);
      final goal = target.type == TargetType.duration
          ? target.durationHours
          : target.frequencyCount.toDouble();
      final unit = target.type == TargetType.duration ? '小时' : '次';
      final amount = target.type == TargetType.duration
          ? _number(current)
          : current.toInt().toString();
      valueText = '$amount / ${_number(goal)} $unit';
      ratio = goal > 0 ? (current / goal).clamp(0.0, 1.0) : 0;
      if (goal <= 0) {
        label = '请设置目标值';
        statusColor = AppSemanticColors.warning;
      } else if (target.compareType == '少于') {
        valueText = '已用 $amount / 上限 ${_number(goal)} $unit';
        final atLimit = (current - goal).abs() < 0.00000001;
        label = atLimit ? '达到上限' : (current > goal ? '已超限' : '未超限');
        statusColor = current >= goal
            ? AppSemanticColors.warning
            : AppSemanticColors.success;
      } else {
        final equal = (current - goal).abs() < 0.00000001;
        final complete = target.compareType == '等于' ? equal : current > goal;
        final excess = target.compareType == '等于' && current > goal && !equal;
        label = complete ? '已达目标' : (excess ? '已超过目标' : '未达目标');
        statusColor = complete
            ? AppSemanticColors.success
            : (excess ? AppSemanticColors.warning : scheme.onSurfaceVariant);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(valueText, style: AppText.body),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              decoration: BoxDecoration(
                color: context.wallpaperFill(
                    AppSemanticColors.tint(statusColor, surface)),
                borderRadius: AppRadius.badgeAll,
              ),
              child: Text(label,
                  style: AppText.caption.copyWith(
                      color: AppSemanticColors.onTint(statusColor, surface))),
            ),
          ],
        ),
        if (ratio != null) ...[
          const SizedBox(height: AppSpacing.sm),
          LinearProgressIndicator(
            value: ratio,
            color: context.wallpaperFill(
                target.compareType == '少于' && label != '未超限'
                    ? AppSemanticColors.warning
                    : scheme.primary),
            backgroundColor:
                context.wallpaperFill(scheme.surfaceContainerHighest),
            borderRadius: AppRadius.gridAll,
          ),
        ],
      ],
    );
  }
}
