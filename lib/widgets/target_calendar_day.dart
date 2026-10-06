import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/target.dart';
import '../models/target_progress.dart';
import '../providers/time_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'target_progress_indicator.dart';
import 'target_day_refresh.dart';

/// 面积与日期数字使用相同裁剪边界，让跨越填充线的数字仍保持对比度。
class TargetCalendarDay extends StatelessWidget {
  const TargetCalendarDay({
    super.key,
    required this.date,
    required this.progress,
    required this.isToday,
    required this.onTap,
  });

  final DateTime date;
  final TargetProgress progress;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final scale = math.max(
        1.0,
        MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) /
            AppText.body.fontSize!);
    final point = progress.target.type == TargetType.timePoint;
    final ratio = point || progress.recordOnly
        ? (progress.hasRecords ? 1.0 : 0.0)
        : progress.ratio;
    final color = targetProgressColor(context, progress);
    // 满格但尚未严格超过，以及多日目标的记录格，使用淡色避免误报达标。
    final pale = progress.recordOnly ||
        progress.status == TargetProgressStatus.notStarted ||
        progress.status == TargetProgressStatus.reachedValue ||
        progress.status == TargetProgressStatus.provisional;
    final fill = pale ? AppSemanticColors.tint(color, surfaces.card) : color;
    final description =
        '${TargetProgress.dateLabel(date)}，${progress.valueLabel}，${progress.statusLabel}';
    final symbol = progress.isAchieved
        ? '✓'
        : progress.isWarning
            ? '!'
            : null;
    Widget contents(Color foreground) => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('${date.day}',
                style: (symbol == null ? AppText.body : AppText.caption)
                    .copyWith(color: foreground)),
            if (symbol != null)
              Icon(symbol == '✓' ? Icons.check : Icons.priority_high,
                  size: AppSizes.targetCalendarStatusIcon, color: foreground),
          ],
        );
    return Semantics(
      button: true,
      label: description,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: description,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.gridAll,
          child: Center(
            child: Container(
              width: AppSizes.targetCalendarDaySize * scale,
              height: AppSizes.targetCalendarDaySize * scale,
              decoration: BoxDecoration(
                borderRadius: AppRadius.gridAll,
                border: isToday
                    ? Border.all(color: scheme.primary, width: AppSizes.border)
                    : null,
              ),
              child: ClipRRect(
                borderRadius: AppRadius.gridAll,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: context.wallpaperFill(surfaces.subtle)),
                    contents(scheme.onSurface),
                    if (ratio > 0)
                      ClipRect(
                        clipper: _AreaClipper(ratio),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(color: context.wallpaperFill(fill)),
                            contents(AppSemanticColors.onColor(fill)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AreaClipper extends CustomClipper<Rect> {
  const _AreaClipper(this.ratio);
  final double ratio;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
      0, size.height * (1 - ratio), size.width, size.height * ratio);

  @override
  bool shouldReclip(_AreaClipper oldClipper) => oldClipper.ratio != ratio;
}

Future<void> showTargetDayDetails(
    BuildContext context, TimeProvider provider, Target target, DateTime date) {
  Widget content(BuildContext context) => TargetDayRefresh(
        builder: (context) => ListenableBuilder(
          listenable: provider,
          builder: (context, _) {
            final current = provider.targetById(target.id);
            if (current == null) return const Text('该目标已删除');
            final day = provider.getTargetDayProgress(current, date);
            final cycle = provider.getTargetProgress(current, date: date);
            final outside = day.status == TargetProgressStatus.outsidePeriod;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(current.name, style: AppText.sectionTitle),
                const SizedBox(height: AppSpacing.md),
                if (day.recordOnly) ...[
                  Text('当天记录：${day.valueLabel}', style: AppText.body),
                  const SizedBox(height: AppSpacing.md),
                  Text('周期进度 · ${cycle.periodLabel}', style: AppText.caption),
                  const SizedBox(height: AppSpacing.sm),
                ],
                TargetProgressIndicator(
                  progress: day.recordOnly && !outside ? cycle : day,
                  surface: AppSurfaces.of(context).overlay,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                    current.type == TargetType.timePoint
                        ? '条件：${current.targetTime} ${current.compareType}\n有效区间：${current.startTime} ～ ${current.endTime}'
                        : '条件：${current.period}，${current.compareType} ${TargetProgress.number(cycle.goal)} ${cycle.unit}',
                    style: AppText.caption),
                if (current.compareType == '少于' ||
                    current.compareType == '等于') ...[
                  const SizedBox(height: AppSpacing.sm),
                  const Text('周期结束前显示当前状态，结束后判定最终是否达标。',
                      style: AppText.caption),
                ],
              ],
            );
          },
        ),
      );
  final platform = Theme.of(context).platform;
  if (platform == TargetPlatform.windows || platform == TargetPlatform.macOS) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppSurfaces.of(context).overlay,
        title: Text(TargetProgress.dateLabel(date)),
        content: SizedBox(
          width: AppSizes.targetCalendarDetailMaxWidth,
          child: SingleChildScrollView(child: content(context)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭'))
        ],
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppSurfaces.of(context).overlay,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: AppSpacing.sheet,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(TargetProgress.dateLabel(date), style: AppText.sectionTitle),
            const SizedBox(height: AppSpacing.md),
            content(context),
            const SizedBox(height: AppSpacing.md),
            Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'))),
          ],
        ),
      ),
    ),
  );
}
