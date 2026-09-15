import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/platform_features.dart';

/// 应用桌面端快捷键的动作类型。
enum DesktopShortcutActionType {
  undo,
  previousDay,
  nextDay,
  today,
  openSearch,
  escape,
}

/// 一个桌面快捷键意图。
class DesktopShortcutIntent extends Intent {
  const DesktopShortcutIntent(this.type);

  final DesktopShortcutActionType type;
}

/// 桌面端快捷键的简洁说明，供帮助入口和测试复用。
class DesktopShortcutHint {
  const DesktopShortcutHint({required this.action, required this.keys});

  final String action;
  final String keys;
}

List<DesktopShortcutHint> desktopShortcutHints({bool? macOS}) {
  final modifier = (macOS ?? Platform.isMacOS) ? '⌘' : 'Ctrl';
  return <DesktopShortcutHint>[
    DesktopShortcutHint(action: '撤销', keys: '$modifier+Z'),
    DesktopShortcutHint(action: '重做', keys: '$modifier+Shift+Z（暂不支持）'),
    const DesktopShortcutHint(action: '前一天', keys: '←'),
    const DesktopShortcutHint(action: '后一天', keys: '→'),
    const DesktopShortcutHint(action: '回今天', keys: 'T'),
    DesktopShortcutHint(
      action: '打开搜索',
      keys: '$modifier+K / $modifier+F',
    ),
    const DesktopShortcutHint(action: '关闭弹层 / 刷子 / 选择', keys: 'Esc'),
  ];
}

/// 判断快捷键当前是否会落在可编辑控件中。
///
/// Action 收到的 context 通常是当前 primary focus 的 context。沿焦点
/// context 向上检查 EditableText 及 Material 输入控件，可以让快捷键在
/// 编辑器内返回 disabled，事件继续交给 Flutter 的文字编辑行为处理。
@visibleForTesting
bool isEditableShortcutContext(BuildContext? context) {
  if (context == null) return false;

  bool isEditableWidget(Widget widget) {
    return widget is EditableText ||
        widget is TextField ||
        widget is TextFormField;
  }

  if (isEditableWidget(context.widget)) return true;

  var editable = false;
  context.visitAncestorElements((element) {
    if (isEditableWidget(element.widget)) {
      editable = true;
      return false;
    }
    return true;
  });
  return editable;
}

typedef _DesktopShortcutCallback = Object? Function(
  DesktopShortcutActionType type,
  BuildContext? context,
);

class _DesktopShortcutAction extends ContextAction<DesktopShortcutIntent> {
  _DesktopShortcutAction({
    required this.callback,
    required this.isAvailable,
  });

  final _DesktopShortcutCallback callback;
  final bool Function(DesktopShortcutActionType type) isAvailable;

  @override
  bool isEnabled(
    DesktopShortcutIntent intent, [
    BuildContext? context,
  ]) {
    // Esc 仍交给宿主决定是否关闭当前临时状态；宿主必须结合当前路由
    // 判断是否真的是可关闭弹层。其余动作在编辑焦点内全部让给文字编辑器。
    if (intent.type != DesktopShortcutActionType.escape &&
        isEditableShortcutContext(context)) {
      return false;
    }
    return isAvailable(intent.type);
  }

  @override
  Object? invoke(
    DesktopShortcutIntent intent, [
    BuildContext? context,
  ]) {
    return callback(intent.type, context);
  }

  @override
  KeyEventResult toKeyEventResult(
    DesktopShortcutIntent intent,
    covariant Object? invokeResult,
  ) {
    // Esc 的回调返回 false 表示当前页面没有可关闭状态，继续向上冒泡，
    // 让根层的弹窗/路由关闭逻辑有机会处理它。
    if (intent.type == DesktopShortcutActionType.escape &&
        invokeResult != true) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
}

/// 桌面端快捷键宿主。
///
/// [enabled] 和 [macOS] 只用于测试或特殊宿主覆盖；生产代码默认读取
/// 当前平台。移动端直接返回 child，不增加 Focus/Shortcuts 层。
class DesktopShortcutHost extends StatelessWidget {
  const DesktopShortcutHost({
    super.key,
    required this.child,
    this.onUndo,
    this.onPreviousDay,
    this.onNextDay,
    this.onToday,
    this.onOpenSearch,
    this.onEscape,
    this.onEscapeWithContext,
    this.enabled,
    this.macOS,
  });

  final Widget child;
  final VoidCallback? onUndo;
  final VoidCallback? onPreviousDay;
  final VoidCallback? onNextDay;
  final VoidCallback? onToday;
  final VoidCallback? onOpenSearch;

  /// 返回 true 表示已关闭某个状态，false 表示继续让事件向上冒泡。
  final bool Function()? onEscape;

  /// 带当前键盘焦点上下文的 Esc 回调。用于根层区分表单页和
  /// barrierDismissible 的 PopupRoute；保留 [onEscape] 兼容页面内快捷键。
  final bool Function(BuildContext? context)? onEscapeWithContext;

  final bool? enabled;
  final bool? macOS;

  @override
  Widget build(BuildContext context) {
    final isEnabled = enabled ?? isDesktopPlatform;
    if (!isEnabled) return child;

    final useMeta = macOS ?? Platform.isMacOS;
    final modifier = <ShortcutActivator, Intent>{
      SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: !useMeta,
        meta: useMeta,
        includeRepeats: false,
      ): const DesktopShortcutIntent(DesktopShortcutActionType.undo),
      SingleActivator(
        LogicalKeyboardKey.arrowLeft,
        includeRepeats: false,
      ): const DesktopShortcutIntent(DesktopShortcutActionType.previousDay),
      SingleActivator(
        LogicalKeyboardKey.arrowRight,
        includeRepeats: false,
      ): const DesktopShortcutIntent(DesktopShortcutActionType.nextDay),
      const SingleActivator(
        LogicalKeyboardKey.keyT,
        includeRepeats: false,
      ): const DesktopShortcutIntent(DesktopShortcutActionType.today),
      SingleActivator(
        LogicalKeyboardKey.keyK,
        control: !useMeta,
        meta: useMeta,
        includeRepeats: false,
      ): const DesktopShortcutIntent(DesktopShortcutActionType.openSearch),
      SingleActivator(
        LogicalKeyboardKey.keyF,
        control: !useMeta,
        meta: useMeta,
        includeRepeats: false,
      ): const DesktopShortcutIntent(DesktopShortcutActionType.openSearch),
      const SingleActivator(
        LogicalKeyboardKey.escape,
        includeRepeats: false,
      ): const DesktopShortcutIntent(DesktopShortcutActionType.escape),
    };

    final callbacks = <DesktopShortcutActionType, VoidCallback?>{
      DesktopShortcutActionType.undo: onUndo,
      DesktopShortcutActionType.previousDay: onPreviousDay,
      DesktopShortcutActionType.nextDay: onNextDay,
      DesktopShortcutActionType.today: onToday,
      DesktopShortcutActionType.openSearch: onOpenSearch,
    };

    return Shortcuts(
      shortcuts: modifier,
      debugLabel: '桌面端快捷键',
      child: Actions(
        actions: <Type, Action<Intent>>{
          DesktopShortcutIntent: _DesktopShortcutAction(
            isAvailable: (type) => type == DesktopShortcutActionType.escape
                ? onEscape != null || onEscapeWithContext != null
                : callbacks[type] != null,
            callback: (type, context) {
              if (type == DesktopShortcutActionType.escape) {
                return onEscapeWithContext?.call(context) ??
                    onEscape?.call() ??
                    false;
              }
              callbacks[type]?.call();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}
