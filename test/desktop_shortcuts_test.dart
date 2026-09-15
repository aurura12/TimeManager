import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/widgets/desktop_shortcut_host.dart';

Future<void> _sendShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool meta = false,
  bool shift = false,
}) async {
  final modifiers = <LogicalKeyboardKey>[
    if (control) LogicalKeyboardKey.controlLeft,
    if (meta) LogicalKeyboardKey.metaLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
  ];
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pump();
}

Widget _shortcutProbe({
  required List<DesktopShortcutActionType> calls,
  required bool enabled,
  required bool macOS,
  bool Function()? onEscape,
  TextEditingController? controller,
}) {
  return MaterialApp(
    home: DesktopShortcutHost(
      enabled: enabled,
      macOS: macOS,
      onUndo: () => calls.add(DesktopShortcutActionType.undo),
      onPreviousDay: () => calls.add(DesktopShortcutActionType.previousDay),
      onNextDay: () => calls.add(DesktopShortcutActionType.nextDay),
      onToday: () => calls.add(DesktopShortcutActionType.today),
      onOpenSearch: () => calls.add(DesktopShortcutActionType.openSearch),
      onEscape: onEscape ??
          () {
            calls.add(DesktopShortcutActionType.escape);
            return true;
          },
      child: Scaffold(
        body: controller == null
            ? const Focus(
                autofocus: true,
                child: SizedBox.expand(),
              )
            : TextField(
                controller: controller,
                autofocus: true,
              ),
      ),
    ),
  );
}

void main() {
  testWidgets('桌面快捷键触发日期、撤销、搜索和 Esc 动作', (tester) async {
    final calls = <DesktopShortcutActionType>[];
    await tester.pumpWidget(
      _shortcutProbe(calls: calls, enabled: true, macOS: false),
    );

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyZ,
      control: true,
    );
    await _sendShortcut(tester, LogicalKeyboardKey.arrowLeft);
    await _sendShortcut(tester, LogicalKeyboardKey.arrowRight);
    await _sendShortcut(tester, LogicalKeyboardKey.keyT);
    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyK,
      control: true,
    );
    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyF,
      control: true,
    );
    await _sendShortcut(tester, LogicalKeyboardKey.escape);

    expect(calls, [
      DesktopShortcutActionType.undo,
      DesktopShortcutActionType.previousDay,
      DesktopShortcutActionType.nextDay,
      DesktopShortcutActionType.today,
      DesktopShortcutActionType.openSearch,
      DesktopShortcutActionType.openSearch,
      DesktopShortcutActionType.escape,
    ]);
  });

  testWidgets('macOS 使用 Command，Ctrl 不会误触发', (tester) async {
    final calls = <DesktopShortcutActionType>[];
    await tester.pumpWidget(
      _shortcutProbe(calls: calls, enabled: true, macOS: true),
    );

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyZ,
      control: true,
    );
    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyZ,
      meta: true,
    );
    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyZ,
      meta: true,
      shift: true,
    );

    expect(calls, [DesktopShortcutActionType.undo]);
  });

  testWidgets('移动端禁用桌面快捷键', (tester) async {
    final calls = <DesktopShortcutActionType>[];
    await tester.pumpWidget(
      _shortcutProbe(calls: calls, enabled: false, macOS: false),
    );

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyZ,
      control: true,
    );
    await _sendShortcut(tester, LogicalKeyboardKey.arrowLeft);
    await _sendShortcut(tester, LogicalKeyboardKey.keyT);

    expect(calls, isEmpty);
  });

  testWidgets('编辑控件获得焦点时不拦截文字编辑快捷键', (tester) async {
    final calls = <DesktopShortcutActionType>[];
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _shortcutProbe(
        calls: calls,
        enabled: true,
        macOS: false,
        controller: controller,
      ),
    );

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyZ,
      control: true,
    );
    await _sendShortcut(tester, LogicalKeyboardKey.arrowLeft);
    await _sendShortcut(tester, LogicalKeyboardKey.keyT);
    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyK,
      control: true,
    );
    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyF,
      control: true,
    );

    expect(calls, isEmpty);
    expect(controller.text, 'abc');
  });

  testWidgets('Esc 没有页面内状态时继续向上冒泡', (tester) async {
    final calls = <DesktopShortcutActionType>[];
    await tester.pumpWidget(
      _shortcutProbe(
        calls: calls,
        enabled: true,
        macOS: false,
        onEscape: () => false,
      ),
    );

    await _sendShortcut(tester, LogicalKeyboardKey.escape);

    expect(calls, isEmpty);
  });

  test('快捷键帮助明确说明当前没有 redo 实现', () {
    final hints = desktopShortcutHints(macOS: false);

    expect(hints.map((hint) => hint.action), contains('重做'));
    expect(
      hints.firstWhere((hint) => hint.action == '重做').keys,
      contains('暂不支持'),
    );
  });
}
