import 'package:flutter/material.dart';

import '../models/global_search_result.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 本地搜索结果的只读详情页。
///
/// 日记、出行与打卡数据在搜索时不应重新触发各自的远程同步，因此点击
/// 这些结果先展示搜索建立时取得的本地详情；时间记录和目标仍由搜索页走各自
/// 的原生日期/详情入口。
class GlobalSearchDetailScreen extends StatelessWidget {
  const GlobalSearchDetailScreen({
    super.key,
    required this.result,
  });

  final GlobalSearchResult result;

  String _formatDate(DateTime date) =>
      '${date.year}年${date.month}月${date.day}日';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final details = result.details?.trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(result.moduleLabel),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: surfaces.card,
              borderRadius: AppRadius.cardAll,
              border: Border.all(color: surfaces.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: AppSemanticColors.tint(
                          colorScheme.primary,
                          surfaces.card,
                        ),
                        borderRadius: AppRadius.badgeAll,
                      ),
                      child: Text(
                        result.moduleLabel,
                        style: AppText.badge.copyWith(
                          color: AppSemanticColors.readableOn(
                            colorScheme.primary,
                            surfaces.card,
                            minRatio: 3,
                          ),
                        ),
                      ),
                    ),
                    if (result.identityLabel != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        result.identityLabel!,
                        style: AppText.caption.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (result.date != null)
                      Text(
                        _formatDate(result.date!),
                        style: AppText.caption.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  result.title,
                  style: AppText.sectionTitle.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  result.summary,
                  style: AppText.body.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (details != null && details.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              '本地详情',
              style: AppText.sectionTitle.copyWith(
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: surfaces.subtle,
                borderRadius: AppRadius.controlAll,
              ),
              child: SelectableText(
                details,
                style: AppText.body.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
