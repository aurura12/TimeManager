import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 刷子模式的状态卡，替换 `TemplateBar` 原来的「模板 + 设置」标题行。
///
/// 侧栏只有 100 宽，所以按列排布：标题行、当前刷子事件、操作提示、退出按钮。
/// 卡片本身就是"刷子模式开着"的唯一指示，退出入口也放在这里。
class BrushModeCard extends StatelessWidget {
  const BrushModeCard({
    super.key,
    required this.label,
    required this.onExit,
  });

  /// 当前刷子事件名：父事件为「学习」，子事件为「研究生 · 出题」
  final String label;

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    // 卡片底是主色 15% 淡色调，压在半透明侧栏上，文字/图标必须按合成后的底取色
    final background =
        AppSemanticColors.tint(colorScheme.primary, surfaces.subtle, 0.15);
    final onBackground = AppSemanticColors.readableOn(
      colorScheme.primary,
      background,
    );
    final borderColor =
        AppSemanticColors.readableOn(colorScheme.primary, background,
            minRatio: 3.0);
    final hintColor = AppSemanticColors.onTint(
      colorScheme.primary,
      surfaces.subtle,
      alpha: 0.15,
      minRatio: 3.0,
    );

    return Semantics(
      label: '刷子模式，当前事件 $label',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: BoxDecoration(
          color: background,
          borderRadius: AppRadius.controlAll,
          border: Border.all(color: borderColor, width: AppSizes.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.brush, size: 14, color: onBackground),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '刷子模式',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.badge.copyWith(
                      color: onBackground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.body.copyWith(
                color: onBackground,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '点击或拖动网格记录',
              style: AppText.caption.copyWith(color: hintColor),
            ),
            const SizedBox(height: AppSpacing.xs),
            TextButton(
              onPressed: onExit,
              style: TextButton.styleFrom(
                foregroundColor: onBackground,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('退出'),
            ),
          ],
        ),
      ),
    );
  }
}
