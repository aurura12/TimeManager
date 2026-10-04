import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/desktop_shortcut.dart';
import '../providers/desktop_shortcut_provider.dart';
import '../utils/platform_features.dart';
import 'main_tab_activity.dart';

export '../models/desktop_shortcut.dart';

class DesktopShortcutHint {
  const DesktopShortcutHint({required this.action, required this.keys});
  final String action;
  final String keys;
}

List<DesktopShortcutHint> desktopShortcutHints({
  bool? macOS,
  Map<DesktopShortcutActionType, DesktopKeyBinding?>? bindings,
}) {
  final useMeta = macOS ?? Platform.isMacOS;
  return [
    for (final entry in (bindings ?? defaultDesktopBindings()).entries)
      DesktopShortcutHint(
        action: entry.key.label,
        keys: entry.value?.label(macOS: useMeta) ?? '已停用',
      ),
  ];
}

String desktopShortcutLabel(
    BuildContext context, DesktopShortcutActionType action) {
  final provider = context.watch<DesktopShortcutProvider?>();
  return (provider?.bindings ?? defaultDesktopBindings())[action]
          ?.label(macOS: Platform.isMacOS) ??
      '';
}

String desktopShortcutTooltip(
    BuildContext context, String label, DesktopShortcutActionType action) {
  if (!isDesktopPlatform) return label;
  final keys = desktopShortcutLabel(context, action);
  return keys.isEmpty ? label : '$label ($keys)';
}

bool _hasAncestorWidget(
    BuildContext? context, bool Function(Widget) predicate) {
  if (context == null) return false;
  if (predicate(context.widget)) return true;
  var found = false;
  context.visitAncestorElements((element) {
    if (!predicate(element.widget)) return true;
    found = true;
    return false;
  });
  return found;
}

@visibleForTesting
bool isEditableShortcutContext(BuildContext? context) => _hasAncestorWidget(
      context,
      (widget) =>
          widget is EditableText ||
          widget is TextField ||
          widget is TextFormField,
    );

bool _isComposing(BuildContext? context) => _hasAncestorWidget(
      context,
      (widget) =>
          widget is EditableText &&
          widget.controller.value.composing.isValid &&
          !widget.controller.value.composing.isCollapsed,
    );

bool _isSelectionControl(BuildContext? context) => _hasAncestorWidget(
      context,
      (widget) =>
          widget is Slider ||
          widget is RangeSlider ||
          widget is DropdownButton ||
          widget is DropdownMenu ||
          widget is RadioGroup,
    );

typedef _ShortcutCallback = bool Function(BuildContext? context);

/// 各宿主只注册自己的命令。调度在 ShortcutManager 内完成，避免内层的
/// 同类型 Action 遮住根层搜索 / 设置，同时保留未处理事件的正常冒泡。
class _DesktopShortcutManager extends ShortcutManager {
  Map<DesktopShortcutActionType, _ShortcutCallback> callbacks = {};
  Map<DesktopShortcutActionType, DesktopKeyBinding?> bindings = {};
  late BuildContext scopeContext;
  bool macOS = false;
  bool pageScoped = true;
  bool active = true;
  bool Function(DesktopShortcutActionType)? isAvailable;

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (!active ||
        (pageScoped && ModalRoute.of(scopeContext)?.isCurrent == false)) {
      return KeyEventResult.ignored;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (_isComposing(focusContext)) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    for (final entry in callbacks.entries) {
      final binding = bindings[entry.key];
      if (binding == null) continue;
      final redoAlias = !macOS &&
          entry.key == DesktopShortcutActionType.redo &&
          binding == defaultDesktopBindings()[DesktopShortcutActionType.redo] &&
          const DesktopKeyBinding(LogicalKeyboardKey.keyY, primary: true)
              .activator(macOS: false)
              .accepts(event, keyboard);
      if (!redoAlias &&
          !binding.activator(macOS: macOS).accepts(event, keyboard)) {
        continue;
      }
      if (isAvailable?.call(entry.key) == false) return KeyEventResult.ignored;
      if (entry.key != DesktopShortcutActionType.escape) {
        final scaffold =
            focusContext == null ? null : Scaffold.maybeOf(focusContext);
        if (scaffold?.isDrawerOpen == true ||
            scaffold?.isEndDrawerOpen == true) {
          return KeyEventResult.ignored;
        }
        final editing = isEditableShortcutContext(focusContext);
        final textOwnsCommand = switch (entry.key) {
          DesktopShortcutActionType.undo ||
          DesktopShortcutActionType.redo ||
          DesktopShortcutActionType.previousDay ||
          DesktopShortcutActionType.nextDay ||
          DesktopShortcutActionType.today ||
          DesktopShortcutActionType.newItem =>
            true,
          _ => !binding.hasModifier,
        };
        if (editing && textOwnsCommand) return KeyEventResult.ignored;
        if (!binding.hasModifier && _isSelectionControl(focusContext)) {
          return KeyEventResult.ignored;
        }
      }
      return entry.value(focusContext)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }
}

class DesktopShortcutHost extends StatefulWidget {
  const DesktopShortcutHost({
    super.key,
    required this.child,
    this.onUndo,
    this.onRedo,
    this.onPreviousDay,
    this.onNextDay,
    this.onToday,
    this.onOpenSearch,
    this.onSearchPage,
    this.onNewItem,
    this.onOpenSettings,
    this.onSaveForm,
    this.onSelectTab,
    this.onEscape,
    this.onEscapeWithContext,
    this.isAvailable,
    this.pageScoped = true,
    this.autofocus = false,
    this.enabled,
    this.macOS,
  });

  final Widget child;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onPreviousDay;
  final VoidCallback? onNextDay;
  final VoidCallback? onToday;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onSearchPage;
  final VoidCallback? onNewItem;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onSaveForm;
  final void Function(int index)? onSelectTab;
  final bool Function()? onEscape;
  final bool Function(BuildContext? context)? onEscapeWithContext;
  final bool Function(DesktopShortcutActionType)? isAvailable;
  final bool pageScoped;
  final bool autofocus;
  final bool? enabled;
  final bool? macOS;

  @override
  State<DesktopShortcutHost> createState() => _DesktopShortcutHostState();
}

class _DesktopShortcutHostState extends State<DesktopShortcutHost> {
  final _manager = _DesktopShortcutManager();
  final _pageFocus = FocusNode(debugLabel: '页面快捷键');
  bool _wasActive = false;

  @override
  void dispose() {
    _manager.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!(widget.enabled ?? isDesktopPlatform)) return widget.child;
    final provider = context.watch<DesktopShortcutProvider?>();
    final callbacks = <DesktopShortcutActionType, _ShortcutCallback>{};
    void add(DesktopShortcutActionType type, VoidCallback? callback) {
      if (callback != null) {
        callbacks[type] = (_) {
          callback();
          return true;
        };
      }
    }

    add(DesktopShortcutActionType.undo, widget.onUndo);
    add(DesktopShortcutActionType.redo, widget.onRedo);
    add(DesktopShortcutActionType.previousDay, widget.onPreviousDay);
    add(DesktopShortcutActionType.nextDay, widget.onNextDay);
    add(DesktopShortcutActionType.today, widget.onToday);
    add(DesktopShortcutActionType.openSearch, widget.onOpenSearch);
    add(DesktopShortcutActionType.searchPage, widget.onSearchPage);
    add(DesktopShortcutActionType.newItem, widget.onNewItem);
    add(DesktopShortcutActionType.openSettings, widget.onOpenSettings);
    add(DesktopShortcutActionType.saveForm, widget.onSaveForm);
    if (widget.onSelectTab != null) {
      final tabs = [
        DesktopShortcutActionType.tab1,
        DesktopShortcutActionType.tab2,
        DesktopShortcutActionType.tab3,
        DesktopShortcutActionType.tab4,
        DesktopShortcutActionType.tab5,
        DesktopShortcutActionType.tab6
      ];
      for (var index = 0; index < tabs.length; index++) {
        final tabIndex = index;
        callbacks[tabs[index]] = (_) {
          widget.onSelectTab!(tabIndex);
          return true;
        };
      }
    }
    if (widget.onEscape != null || widget.onEscapeWithContext != null) {
      callbacks[DesktopShortcutActionType.escape] = (focusContext) =>
          widget.onEscapeWithContext?.call(focusContext) ??
          widget.onEscape?.call() ??
          false;
    }
    _manager
      ..scopeContext = context
      ..callbacks = callbacks
      ..bindings = provider?.bindings ?? defaultDesktopBindings()
      ..macOS = widget.macOS ?? Platform.isMacOS
      ..pageScoped = widget.pageScoped
      ..active = !widget.pageScoped || MainTabActivity.isActiveOf(context)
      ..isAvailable = widget.isAvailable;
    if (widget.autofocus && _manager.active && !_wasActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _manager.active &&
            !_pageFocus.hasFocus &&
            ModalRoute.of(context)?.isCurrent != false) {
          _pageFocus.requestFocus();
        }
      });
    }
    _wasActive = _manager.active;
    return Shortcuts.manager(
        manager: _manager,
        child: Focus(focusNode: _pageFocus, child: widget.child));
  }
}
