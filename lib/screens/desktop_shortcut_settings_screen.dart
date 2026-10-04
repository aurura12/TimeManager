import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/desktop_shortcut_provider.dart';
import '../theme/app_tokens.dart';
import '../widgets/desktop_shortcut_host.dart';

class DesktopShortcutSettingsScreen extends StatefulWidget {
  const DesktopShortcutSettingsScreen(
      {super.key, required this.provider, this.macOS});

  final DesktopShortcutProvider provider;
  final bool? macOS;

  static void open(BuildContext context) {
    final provider = context.read<DesktopShortcutProvider?>();
    if (provider == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DesktopShortcutSettingsScreen(provider: provider),
    ));
  }

  @override
  State<DesktopShortcutSettingsScreen> createState() =>
      _DesktopShortcutSettingsScreenState();
}

class _DesktopShortcutSettingsScreenState
    extends State<DesktopShortcutSettingsScreen> {
  Map<DesktopShortcutActionType, DesktopKeyBinding?>? _draft;
  bool _saving = false;
  String? _error;
  bool get _macOS => widget.macOS ?? Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    if (widget.provider.isLoaded) {
      _draft = Map.of(widget.provider.bindings);
    } else {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    await widget.provider.ready;
    if (mounted) setState(() => _draft = Map.of(widget.provider.bindings));
  }

  Future<void> _save() async {
    if (_saving || _draft == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.provider.save(_draft!);
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存快捷键失败，请重试';
        });
      }
    }
  }

  Future<void> _edit(DesktopShortcutActionType action) async {
    final binding = await showDialog<DesktopKeyBinding>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BindingCaptureDialog(
        action: action,
        bindings: _draft!,
        macOS: _macOS,
      ),
    );
    if (binding != null && mounted) {
      setState(() {
        _draft![action] = binding;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    final scheme = Theme.of(context).colorScheme;
    return DesktopShortcutHost(
      autofocus: true,
      macOS: widget.macOS,
      onSaveForm: () => unawaited(_save()),
      isAvailable: (_) => !_saving && draft != null,
      child: PopScope(
        canPop: !_saving,
        child: Scaffold(
          appBar: AppBar(title: const Text('键盘快捷键'), actions: [
            TextButton(
              onPressed: _saving || draft == null
                  ? null
                  : () => setState(() {
                        _draft = defaultDesktopBindings();
                        _error = null;
                      }),
              child: const Text('恢复默认'),
            ),
          ]),
          body: Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: AppSizes.desktopFormMaxWidth),
              child: draft == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: AppSpacing.cardComfortable,
                          child: Text(
                            '点击组合键修改，或关闭开关停用。保存后立即生效，仅保存在本机。'
                            '\n输入框保留文字撤销和光标移动；中文输入组词时不触发应用命令。'
                            '${_macOS ? '' : '\n默认重做也支持 Ctrl+Y。'}',
                            style: AppText.body
                                .copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                        Expanded(
                            child: ListView.separated(
                          padding: AppSpacing.page,
                          itemCount: DesktopShortcutActionType.values.length,
                          separatorBuilder: (_, index) =>
                              const Divider(height: AppSizes.hairline),
                          itemBuilder: (context, index) {
                            final action =
                                DesktopShortcutActionType.values[index];
                            final binding = draft[action];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  vertical: AppSpacing.sm),
                              title: Text(action.label),
                              subtitle: Text(action.description),
                              trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    OutlinedButton(
                                      key: ValueKey(
                                          'shortcut-edit-${action.name}'),
                                      onPressed:
                                          _saving ? null : () => _edit(action),
                                      child: Text(
                                          binding?.label(macOS: _macOS) ??
                                              '设置按键'),
                                    ),
                                    const SizedBox(width: AppSpacing.sm),
                                    Switch(
                                      key: ValueKey(
                                          'shortcut-toggle-${action.name}'),
                                      value: binding != null,
                                      onChanged: _saving
                                          ? null
                                          : (enabled) async {
                                              if (!enabled) {
                                                setState(
                                                    () => draft[action] = null);
                                                return;
                                              }
                                              final fallback =
                                                  defaultDesktopBindings()[
                                                      action]!;
                                              if (validateDesktopBinding(action,
                                                      fallback, draft) ==
                                                  null) {
                                                setState(() =>
                                                    draft[action] = fallback);
                                              } else {
                                                await _edit(action);
                                              }
                                            },
                                    ),
                                  ]),
                            );
                          },
                        )),
                        SafeArea(
                            top: false,
                            child: Padding(
                              padding: AppSpacing.cardComfortable,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_error != null) ...[
                                      Text(_error!,
                                          style: AppText.body
                                              .copyWith(color: scheme.error)),
                                      const SizedBox(height: AppSpacing.sm),
                                    ],
                                    FilledButton(
                                        onPressed: _saving ? null : _save,
                                        child:
                                            Text(_saving ? '正在保存…' : '保存设置')),
                                  ]),
                            )),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BindingCaptureDialog extends StatefulWidget {
  const _BindingCaptureDialog(
      {required this.action, required this.bindings, required this.macOS});
  final DesktopShortcutActionType action;
  final Map<DesktopShortcutActionType, DesktopKeyBinding?> bindings;
  final bool macOS;

  @override
  State<_BindingCaptureDialog> createState() => _BindingCaptureDialogState();
}

class _BindingCaptureDialogState extends State<_BindingCaptureDialog> {
  DesktopKeyBinding? _binding;
  String? _error;

  KeyEventResult _capture(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.tab) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed) {
      // Enter 留给当前聚焦按钮，避免聚焦“取消”时误确认新绑定。
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (LogicalKeyboardKey.isControlCharacter(key.keyLabel) ||
        key.keyLabel.isEmpty ||
        [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlRight,
          LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.metaRight,
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight,
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.altRight
        ].contains(key)) {
      return KeyEventResult.handled;
    }
    final binding = DesktopKeyBinding(
      key,
      primary:
          widget.macOS ? keyboard.isMetaPressed : keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
    );
    setState(() {
      _binding = binding;
      _error =
          (widget.macOS ? keyboard.isControlPressed : keyboard.isMetaPressed)
              ? '请使用当前系统的 ${widget.macOS ? '⌘' : 'Ctrl'} 修饰键'
              : validateDesktopBinding(widget.action, binding, widget.bindings);
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
        autofocus: true,
        onKeyEvent: _capture,
        child: AlertDialog(
          title: Text('修改${widget.action.label}'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('直接按下新的组合键，Esc 取消。'),
                const SizedBox(height: AppSpacing.lg),
                Text(_binding?.label(macOS: widget.macOS) ?? '等待按键…',
                    style: AppText.pageTitle),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(_error!,
                      style: AppText.body.copyWith(
                          color: Theme.of(context).colorScheme.error)),
                ],
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消')),
            FilledButton(
                onPressed: _binding == null || _error != null
                    ? null
                    : () => Navigator.of(context).pop(_binding),
                child: const Text('使用此按键')),
          ],
        ),
      );
}
