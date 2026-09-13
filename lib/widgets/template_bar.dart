import 'package:flutter/material.dart';
import '../models/schedule_template.dart';
import '../providers/time_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class TemplateBar extends StatelessWidget {
  final TimeProvider provider;
  final void Function(ScheduleTemplate template) onTemplateTap;
  final VoidCallback onManageTap;
  final VoidCallback onCopyYesterdayTap;
  final VoidCallback? onVoiceTap;

  const TemplateBar({
    super.key,
    required this.provider,
    required this.onTemplateTap,
    required this.onManageTap,
    required this.onCopyYesterdayTap,
    this.onVoiceTap,
  });

  static const double _chipHeight = AppSizes.chip;
  static const double _chipGap = AppSpacing.xs;
  static const double _maxListHeight = 126;

  @override
  Widget build(BuildContext context) {
    final templates = provider.templates;
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final chipCount = templates.length + 1;
    final listHeight = (chipCount * _chipHeight + (chipCount - 1) * _chipGap)
        .clamp(_chipHeight, _maxListHeight)
        .toDouble();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(6, 8, 2, 6),
      decoration: BoxDecoration(
        color: surfaces.subtle,
        border: Border(bottom: BorderSide(color: surfaces.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '模板',
                style: AppText.body.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onManageTap,
                icon: const Icon(Icons.settings, size: 22),
                color: colorScheme.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: '管理模板',
              ),
            ],
          ),
          if (onVoiceTap != null) ...[
            const SizedBox(height: _chipGap),
            Semantics(
              button: true,
              label: '语音添加日程',
              child: Material(
                color: surfaces.card,
                borderRadius: AppRadius.badgeAll,
                child: InkWell(
                  onTap: onVoiceTap,
                  borderRadius: AppRadius.badgeAll,
                  child: SizedBox(
                    height: _chipHeight,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.mic_none,
                          size: 16,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '语音添加',
                          style: AppText.badge.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
          SizedBox(
            height: templates.isEmpty ? _chipHeight : listHeight,
            child: templates.isEmpty
                ? _TemplateChip(
                    name: '昨天',
                    onTap: onCopyYesterdayTap,
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: chipCount,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: _chipGap),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _TemplateChip(
                          name: '昨天',
                          onTap: onCopyYesterdayTap,
                        );
                      }
                      final template = templates[index - 1];
                      return _TemplateChip(
                        name: template.name,
                        onTap: () => onTemplateTap(template),
                      );
                    },
                  ),
          ),
          if (templates.isEmpty) ...[
            const SizedBox(height: _chipGap),
            GestureDetector(
              onTap: onManageTap,
              child: Container(
                height: _chipHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: surfaces.card,
                  borderRadius: AppRadius.badgeAll,
                  border: Border.all(color: surfaces.border),
                ),
                child: Text(
                  '添加模板',
                  style: AppText.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TemplateChip extends StatelessWidget {
  final String name;
  final VoidCallback onTap;

  const _TemplateChip({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: name,
      child: Material(
        // 模板 chip 统一用 primaryContainer，浅色/深色一致，不再各写一套
        color: colorScheme.primaryContainer,
        borderRadius: AppRadius.badgeAll,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.badgeAll,
          child: Container(
            height: TemplateBar._chipHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.badge.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
