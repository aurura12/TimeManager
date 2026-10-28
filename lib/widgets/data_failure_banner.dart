import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 数据层故障的置顶横幅（初始化失败 / 本地保存失败）。
///
/// 这两类故障在界面上都表现为「怎么点都没反应」或「改完就没了」，如果不主动说出来，
/// 用户只会以为应用坏了。横幅**不提供关闭**——状态没恢复之前关掉，等于继续让用户白点。
class DataFailureBanner extends StatelessWidget {
  const DataFailureBanner({
    super.key,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;

  /// 具体原因；为空时用通用文案。
  final String? message;

  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final theme = Theme.of(context);
    // danger 实色压在白卡片上只有约 3.3:1，图标 / 强调文字先压到可读
    final accent = AppSemanticColors.readableOn(
      AppSemanticColors.danger,
      surfaces.card,
    );
    final detail = (message?.trim().isNotEmpty ?? false)
        ? message!.trim()
        : '请重启应用后再试；若反复出现，请查看运行日志';
    final showAction = actionLabel != null && onAction != null;

    return Semantics(
      container: true,
      liveRegion: true,
      label: '$title。$detail',
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: context.wallpaperFill(surfaces.card),
          border: Border(bottom: BorderSide(color: surfaces.joinDivider)),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 20, color: accent),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (showAction)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(foregroundColor: accent),
                child: Text(actionLabel!),
              ),
          ],
        ),
      ),
    );
  }
}
