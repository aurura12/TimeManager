import 'dart:async';

import 'package:flutter/material.dart';

import '../models/event_label_style.dart';
import '../providers/event_label_style_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/event_label_text.dart';

/// 「事件名显示」设置：选一行还是两行，并现场预览效果。
///
/// 无论选哪种，只要名字被截断，手机长按、桌面悬停都能看到完整名称，
/// 所以这里不做互斥——两行也照样能长按，避免超长名字彻底看不到。
class EventLabelSettingsScreen extends StatefulWidget {
  const EventLabelSettingsScreen({super.key, required this.provider});

  final EventLabelStyleProvider provider;

  @override
  State<EventLabelSettingsScreen> createState() =>
      _EventLabelSettingsScreenState();
}

class _EventLabelSettingsScreenState extends State<EventLabelSettingsScreen> {
  String? _saveError;

  Future<void> _select(EventLabelStyle style) async {
    if (widget.provider.style == style) return;
    setState(() => _saveError = null);
    try {
      await widget.provider.setStyle(style);
    } on Object {
      if (!mounted) return;
      setState(() => _saveError = '保存设置失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('事件名显示')),
      body: ListenableBuilder(
        listenable: widget.provider,
        builder: (context, _) {
          final style = widget.provider.style;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppSizes.desktopFormMaxWidth,
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.pageHorizontal,
                  vertical: AppSpacing.sm,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: Text(
                      '名字放不下时，手机长按、桌面悬停即可看到完整名称，'
                      '还会带上时间段和所属事件。',
                      style: AppText.body.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Card(
                    margin: EdgeInsets.zero,
                    color: context.wallpaperFill(AppSurfaces.of(context).card),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0;
                            i < EventLabelStyle.values.length;
                            i++) ...[
                          if (i > 0)
                            const Divider(
                              height: AppSizes.hairline,
                              indent: AppSpacing.lg,
                            ),
                          _buildOption(
                              context, EventLabelStyle.values[i], style),
                        ],
                      ],
                    ),
                  ),
                  if (_saveError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(
                        _saveError!,
                        style: AppText.body.copyWith(color: scheme.error),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('预览', style: AppText.sectionTitle),
                  const SizedBox(height: AppSpacing.sm),
                  _buildPreview(context, style),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildOption(
    BuildContext context,
    EventLabelStyle option,
    EventLabelStyle current,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final selected = option == current;
    return ListTile(
      key: ValueKey('event-label-option-${option.id}'),
      title: Text(
        option == EventLabelStyle.twoLines ? '分两行显示' : '只显示一行',
        style: AppText.sectionTitle,
      ),
      subtitle: Text(
        option == EventLabelStyle.twoLines
            ? '用格子的纵向空间多放几个字，名字仍可能被省略'
            : '格子更整齐，长名字靠长按 / 悬停查看',
        style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      onTap: () => _select(option),
    );
  }

  /// 用真实的网格块尺寸（一格 10 分钟）预览，避免"设置页好看、网格里难看"。
  Widget _buildPreview(BuildContext context, EventLabelStyle style) {
    final surfaces = AppSurfaces.of(context);
    final scheme = Theme.of(context).colorScheme;
    const previewWidth = 56.0;
    const samples = <String>['和导师讨论数据', '学习英语'];
    return Card(
      margin: EdgeInsets.zero,
      color: context.wallpaperFill(surfaces.card),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (final sample in samples) ...[
                  Container(
                    width: previewWidth,
                    height: AppSizes.gridRow,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: AppRadius.gridAll,
                    ),
                    child: Center(
                      child: EventLabelText(
                        text: sample,
                        maxLines: style.maxLines,
                        detail: '09:10–09:30 · 学习',
                        style: AppText.gridLabel.copyWith(
                          color: AppSemanticColors.onColor(scheme.primary),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              style == EventLabelStyle.twoLines
                  ? '一格 10 分钟宽约 56px，两行能放下 8～10 个字。'
                  : '单行能放下 4～5 个字，其余靠长按 / 悬停查看。',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
