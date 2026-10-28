import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 本地数据初始化失败时置顶显示的横幅。
///
/// 失败后 `TimeProvider` 会把所有编辑变成 no-op，界面却和「这一天还空着」
/// 完全一样，用户只会觉得应用坏了。这条横幅把失败原因和日志入口直接摆在首页，
/// 并且**不提供关闭**——状态没恢复之前关掉，等于继续让用户白点。
class InitializationFailureBanner extends StatelessWidget {
  const InitializationFailureBanner({
    super.key,
    this.message,
    this.onViewLogs,
  });

  /// Provider 给出的失败原因；为空时用通用文案。
  final String? message;

  final VoidCallback? onViewLogs;

  static const String title = '本地数据未能加载，编辑已暂停';

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
            if (onViewLogs != null)
              TextButton(
                onPressed: onViewLogs,
                style: TextButton.styleFrom(foregroundColor: accent),
                child: const Text('查看日志'),
              ),
          ],
        ),
      ),
    );
  }
}
