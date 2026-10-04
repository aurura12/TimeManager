import 'dart:async';

import 'package:flutter/material.dart';

import '../models/main_tab_id.dart';
import '../providers/main_tab_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class MainTabSettingsScreen extends StatefulWidget {
  const MainTabSettingsScreen({super.key, required this.provider});

  final MainTabProvider provider;

  @override
  State<MainTabSettingsScreen> createState() => _MainTabSettingsScreenState();
}

class _MainTabSettingsScreenState extends State<MainTabSettingsScreen> {
  List<MainTabId>? _order;
  Set<MainTabId> _hiddenTabs = {};
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    if (widget.provider.isLoaded) {
      _readDraft();
    } else {
      unawaited(_loadDraft());
    }
  }

  void _readDraft() {
    _order = widget.provider.order.toList();
    _hiddenTabs = widget.provider.hiddenTabs.toSet();
  }

  Future<void> _loadDraft() async {
    await widget.provider.ready;
    if (mounted) setState(_readDraft);
  }

  void _reorder(int oldIndex, int newIndex) {
    if (_saving) return;
    if (newIndex == oldIndex) return;
    setState(() {
      final tab = _order!.removeAt(oldIndex);
      _order!.insert(newIndex, tab);
      _saveError = null;
    });
  }

  void _reset() {
    setState(() {
      _order = MainTabId.values.toList();
      _hiddenTabs = {};
      _saveError = null;
    });
  }

  Future<void> _save() async {
    if (_saving || _order == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.provider.save(order: _order!, hiddenTabs: _hiddenTabs);
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = '保存标签设置失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('底部标签'),
          actions: [
            TextButton(
              onPressed: _saving || order == null ? null : _reset,
              child: const Text('恢复默认'),
            ),
          ],
        ),
        body: order == null
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppSizes.desktopFormMaxWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: AppSpacing.cardComfortable,
                        child: Text(
                          '开关控制显示，拖动左侧手柄调整顺序，也可用右侧菜单上移或下移。'
                          '\n至少显示两个标签，“我的”始终显示。',
                          style: AppText.body.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ReorderableListView.builder(
                          padding: AppSpacing.page,
                          buildDefaultDragHandles: false,
                          itemCount: order.length,
                          onReorderItem: _reorder,
                          proxyDecorator: (child, index, animation) => Material(
                            color: context.wallpaperFill(surfaces.card),
                            borderRadius: AppRadius.cardAll,
                            child: child,
                          ),
                          itemBuilder: (context, index) =>
                              _buildTabRow(context, order[index], index),
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: AppSpacing.cardComfortable,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_saveError != null)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: AppSpacing.sm,
                                  ),
                                  child: Text(
                                    _saveError!,
                                    style: AppText.body.copyWith(
                                      color: scheme.error,
                                    ),
                                  ),
                                ),
                              FilledButton(
                                onPressed: _saving ? null : _save,
                                child: Text(_saving ? '正在保存…' : '保存设置'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildTabRow(BuildContext context, MainTabId tab, int index) {
    final visible = !_hiddenTabs.contains(tab);
    final locked = tab == MainTabId.profile;
    final minimumReached = _order!.length - _hiddenTabs.length <=
        MainTabProvider.minimumVisibleTabs;
    final canToggle = !_saving && !locked && (!visible || !minimumReached);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('main-tab-row-${tab.id}'),
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      color: context.wallpaperFill(AppSurfaces.of(context).card),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        leading: Tooltip(
          message: '拖动排序：${tab.label}',
          child: ReorderableDragStartListener(
            key: ValueKey('main-tab-drag-${tab.id}'),
            index: index,
            enabled: !_saving,
            child: MouseRegion(
              cursor:
                  _saving ? SystemMouseCursors.basic : SystemMouseCursors.grab,
              child: SizedBox.square(
                dimension: AppSizes.minTapTarget,
                child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
        title: Text(tab.label, style: AppText.sectionTitle),
        subtitle: Text(
          locked
              ? '始终显示'
              : visible
                  ? '已显示'
                  : '已隐藏',
          style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: '显示${tab.label}标签',
              child: Switch(
                key: ValueKey('main-tab-switch-${tab.id}'),
                value: visible,
                onChanged: canToggle
                    ? (value) => setState(() {
                          if (value) {
                            _hiddenTabs.remove(tab);
                          } else {
                            _hiddenTabs.add(tab);
                          }
                          _saveError = null;
                        })
                    : null,
              ),
            ),
            PopupMenuButton<int>(
              tooltip: '调整顺序：${tab.label}',
              enabled: !_saving,
              icon: const Icon(Icons.more_vert),
              onSelected: (direction) => _reorder(index, index + direction),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: -1,
                  enabled: index > 0,
                  child: const Text('上移'),
                ),
                PopupMenuItem(
                  value: 1,
                  enabled: index < _order!.length - 1,
                  child: const Text('下移'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
