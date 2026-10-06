import 'package:flutter/material.dart';

import '../models/target.dart';
import '../models/target_progress.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

Color targetProgressColor(BuildContext context, TargetProgress progress) {
  if (progress.isWarning) return AppSemanticColors.warning;
  if (progress.isAchieved) return AppSemanticColors.success;
  return Theme.of(context).colorScheme.primary;
}

/// 桌面卡片、手机卡片与日期明细使用相同的数量和状态。
class TargetProgressIndicator extends StatelessWidget {
  const TargetProgressIndicator({
    super.key,
    required this.progress,
    this.foregroundColor,
    this.surface,
    this.showTodayLabel = false,
  });

  final TargetProgress progress;
  final Color? foregroundColor;
  final Color? surface;
  final bool showTodayLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = surface ?? AppSurfaces.of(context).card;
    final color = targetProgressColor(context, progress);
    final barCandidate =
        AppSemanticColors.readableOn(color, background, minRatio: 3);
    final barColor =
        AppSemanticColors.contrastRatio(barCandidate, background) >= 3
            ? barCandidate
            : AppSemanticColors.onColor(background);
    final tint = AppSemanticColors.tint(color, background);
    final textCandidate = AppSemanticColors.onTint(color, background);
    final badgeText =
        AppSemanticColors.contrastRatio(textCandidate, tint) >= 4.5
            ? textCandidate
            : AppSemanticColors.onColor(tint);
    final label = showTodayLabel && progress.target.type == TargetType.timePoint
        ? '今日${progress.statusLabel}'
        : progress.statusLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(progress.valueLabel,
                style: AppText.body
                    .copyWith(color: foregroundColor ?? scheme.onSurface)),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              decoration: BoxDecoration(
                color: context.wallpaperFill(tint),
                borderRadius: AppRadius.badgeAll,
              ),
              child: Text(label,
                  style: AppText.caption.copyWith(color: badgeText)),
            ),
          ],
        ),
        if (progress.target.type != TargetType.timePoint) ...[
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            label: progress.target.compareType == '少于' ? '额度占用' : '记录进度',
            value: '${(progress.ratio * 100).round()}%，${progress.statusLabel}',
            child: LinearProgressIndicator(
              value: progress.ratio,
              color: context.wallpaperFill(barColor),
              backgroundColor: context.wallpaperFill(AppSemanticColors.tint(
                  foregroundColor ?? scheme.onSurface, background)),
              borderRadius: AppRadius.gridAll,
            ),
          ),
        ],
      ],
    );
  }
}
