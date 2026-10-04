import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/desktop_layout_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class DesktopLayoutSettingsScreen extends StatefulWidget {
  const DesktopLayoutSettingsScreen({super.key, required this.provider});

  final DesktopLayoutProvider provider;

  @override
  State<DesktopLayoutSettingsScreen> createState() =>
      _DesktopLayoutSettingsScreenState();
}

class _DesktopLayoutSettingsScreenState
    extends State<DesktopLayoutSettingsScreen> {
  bool _saving = false;
  String? _error;

  Future<void> _save(Future<void> Function() update) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await update();
    } on Object {
      if (mounted) setState(() => _error = '保存桌面布局失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('桌面布局')),
      body: AnimatedBuilder(
        animation: widget.provider,
        builder: (context, _) {
          final provider = widget.provider;
          if (!provider.isLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: AppSizes.desktopFormMaxWidth),
              child: ListView(
                padding: AppSpacing.cardComfortable,
                children: [
                  Text('导航位置', style: AppText.sectionTitle),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '选择后立即生效，仅保存在本机。标签的显示与排序沿用“底部标签”设置。',
                    style:
                        AppText.body.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  for (final layout in DesktopNavigationLayout.values) ...[
                    Material(
                      key: ValueKey('desktop-layout-${layout.name}'),
                      color: context.wallpaperFill(
                        provider.navigationLayout == layout
                            ? scheme.primaryContainer
                            : surfaces.card,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: AppRadius.controlAll,
                        side: BorderSide(color: surfaces.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Semantics(
                        selected: provider.navigationLayout == layout,
                        child: ListTile(
                          contentPadding: AppSpacing.cardComfortable,
                          leading: Icon(layout == DesktopNavigationLayout.side
                              ? Icons.view_sidebar_outlined
                              : Icons.vertical_split_outlined),
                          title: Text(layout == DesktopNavigationLayout.bottom
                              ? '底部导航（原有布局）'
                              : '左侧导航（宽屏布局）'),
                          subtitle: Text(
                              layout == DesktopNavigationLayout.bottom
                                  ? '导航始终在窗口底部，保持原来的使用习惯。'
                                  : '宽屏时导航在左侧；窗口较窄时自动回到底部。'),
                          trailing: Icon(provider.navigationLayout == layout
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off),
                          onTap: _saving
                              ? null
                              : () => unawaited(_save(
                                  () => provider.setNavigationLayout(layout))),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (_saving) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text(_error!,
                          style: AppText.body.copyWith(color: scheme.error)),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('事件选择区', style: AppText.sectionTitle),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '在记录页拖动事件栏左边的分隔条调节宽度；栏越宽，事件会自动分成更多列并排显示。'
                    '\n调整后的宽度会记住；窗口缩小时会自动留出日程空间。双击分隔条可恢复默认宽度。',
                    style:
                        AppText.body.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text('当前偏好宽度：${provider.categoryPanelWidth.round()}',
                      style: AppText.caption
                          .copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : () => unawaited(
                              _save(provider.resetCategoryPanelWidth)),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('恢复事件栏默认宽度'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
