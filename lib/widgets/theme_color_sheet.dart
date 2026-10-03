import 'package:flutter/material.dart';

import '../providers/theme_mode_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

Future<void> showThemeColorSheet(
  BuildContext context, {
  required ThemeModeProvider provider,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppSurfaces.of(context).overlay,
    shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
    clipBehavior: Clip.antiAlias,
    builder: (_) => _ThemeColorSheet(provider: provider),
  );
}

class _ThemeColorSheet extends StatefulWidget {
  const _ThemeColorSheet({required this.provider});

  final ThemeModeProvider provider;

  @override
  State<_ThemeColorSheet> createState() => _ThemeColorSheetState();
}

class _ThemeColorSheetState extends State<_ThemeColorSheet> {
  late Color _draftColor;
  late final TextEditingController _hexController;
  String? _inputError;
  String? _saveError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draftColor = widget.provider.themeColor;
    _hexController = TextEditingController(
      text: AppThemeColorPreset.hexOf(_draftColor),
    );
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _selectColor(Color color) {
    setState(() {
      _draftColor = color;
      _hexController.text = AppThemeColorPreset.hexOf(color);
      _inputError = null;
      _saveError = null;
    });
  }

  void _updateHex(String value) {
    final color = AppSemanticColors.parseOpaqueHex(value);
    setState(() {
      if (color != null) _draftColor = color;
      _inputError = color == null ? '请输入合法的 6 位或 8 位十六进制色值' : null;
      _saveError = null;
    });
  }

  Future<void> _apply() async {
    if (_saving || _inputError != null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.provider.setThemeColor(_draftColor);
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = '保存主题色失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 浮层始终不透明；局部主题让预览跟随草稿，不提前保存用户的选择。
    final previewTheme = AppTheme.themeFor(
      Theme.of(context).brightness,
      seedColor: _draftColor,
    );
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Theme(
      data: previewTheme,
      child: Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final surfaces = AppSurfaces.of(context);
        return Material(
          color: surfaces.overlay,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.lg + bottomInset,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('主题色', style: AppText.sectionTitle),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed:
                          _saving ? null : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text(
                  '预览按钮与选中状态的配色，满意后应用。',
                  style: AppText.caption.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final preset in AppThemeColorPreset.values)
                      ChoiceChip(
                        avatar: Icon(
                          Icons.circle,
                          color: preset.color,
                          size: AppSpacing.xl,
                        ),
                        label: Text(preset.label),
                        selected: _draftColor == preset.color,
                        showCheckmark: false,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onSelected:
                            _saving ? null : (_) => _selectColor(preset.color),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  controller: _hexController,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: '自定义色值',
                    hintText: '#RRGGBB',
                    helperText: '例如 #4DA8EE；支持粘贴 6 位或 8 位色值',
                    errorText: _inputError,
                  ),
                  onChanged: _updateHex,
                  onSubmitted: (_) => _apply(),
                ),
                const SizedBox(height: AppSpacing.lg),
                Container(
                  width: double.infinity,
                  padding: AppSpacing.cardComfortable,
                  decoration: BoxDecoration(
                    color: surfaces.subtle,
                    borderRadius: AppRadius.cardAll,
                    border: Border.all(color: surfaces.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('配色预览', style: AppText.body),
                      const SizedBox(height: AppSpacing.md),
                      Wrap(
                        spacing: AppSpacing.md,
                        runSpacing: AppSpacing.sm,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                              vertical: AppSpacing.md,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: AppRadius.controlAll,
                            ),
                            child: Text(
                              '主按钮',
                              style: AppText.button.copyWith(
                                color: scheme.onPrimary,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                              vertical: AppSpacing.md,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: AppRadius.controlAll,
                            ),
                            child: Text(
                              '选中状态',
                              style: AppText.button.copyWith(
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (_saveError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      _saveError!,
                      style: AppText.caption.copyWith(color: scheme.error),
                    ),
                  ),
                TextButton.icon(
                  onPressed:
                      _saving ? null : () => _selectColor(AppTheme.seedColor),
                  icon: const Icon(Icons.restore),
                  label: const Text('恢复默认绿'),
                ),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving || _inputError != null ? null : _apply,
                    child: Text(_saving ? '正在保存…' : '应用主题色'),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}
