import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/main.dart' show isDismissiblePopupRoute;
import 'package:time_manager/providers/desktop_shortcut_provider.dart';
import 'package:time_manager/widgets/desktop_shortcut_host.dart';
import 'package:time_manager/widgets/main_tab_activity.dart';

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
  bool Function(BuildContext? context)? onEscapeWithContext,
  TextEditingController? controller,
}) {
  return MaterialApp(
    home: DesktopShortcutHost(
      enabled: enabled,
      macOS: macOS,
      onUndo: () => calls.add(DesktopShortcutActionType.undo),
      onRedo: () => calls.add(DesktopShortcutActionType.redo),
      onPreviousDay: () => calls.add(DesktopShortcutActionType.previousDay),
      onNextDay: () => calls.add(DesktopShortcutActionType.nextDay),
      onToday: () => calls.add(DesktopShortcutActionType.today),
      onOpenSearch: () => calls.add(DesktopShortcutActionType.openSearch),
      onSearchPage: () => calls.add(DesktopShortcutActionType.searchPage),
      onNewItem: () => calls.add(DesktopShortcutActionType.newItem),
      onSaveForm: () => calls.add(DesktopShortcutActionType.saveForm),
      onOpenSettings: () => calls.add(DesktopShortcutActionType.openSettings),
      onEscape: onEscape ??
          () {
            calls.add(DesktopShortcutActionType.escape);
            return true;
          },
      onEscapeWithContext: onEscapeWithContext,
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
      DesktopShortcutActionType.searchPage,
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

    expect(calls,
        [DesktopShortcutActionType.undo, DesktopShortcutActionType.redo]);
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

    expect(calls, [
      DesktopShortcutActionType.openSearch,
      DesktopShortcutActionType.searchPage
    ]);
    expect(controller.text, 'abc');
  });

  testWidgets('输入框中按 Esc 不会关闭添加/编辑表单页', (tester) async {
    final controller = TextEditingController(text: '待保存内容');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopShortcutHost(
          enabled: true,
          macOS: false,
          onEscapeWithContext: (focusContext) {
            final route =
                focusContext == null ? null : ModalRoute.of(focusContext);
            if (!isDismissiblePopupRoute(route)) return false;
            Navigator.of(focusContext!).pop();
            return true;
          },
          child: Scaffold(
            body: Column(
              children: [
                const Text('添加/编辑目标'),
                TextField(
                  controller: controller,
                  autofocus: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await _sendShortcut(tester, LogicalKeyboardKey.escape);

    expect(find.text('添加/编辑目标'), findsOneWidget);
    expect(controller.text, '待保存内容');
  });

  testWidgets('Esc 可以关闭带输入框的可关闭弹层', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopShortcutHost(
          enabled: true,
          macOS: false,
          onEscapeWithContext: (focusContext) {
            final route =
                focusContext == null ? null : ModalRoute.of(focusContext);
            if (!isDismissiblePopupRoute(route)) return false;
            Navigator.of(focusContext!).pop();
            return true;
          },
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(
                      content: TextField(
                        key: ValueKey<String>('popup-input'),
                        autofocus: true,
                      ),
                    ),
                  );
                },
                child: const Text('打开弹层'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开弹层'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('popup-input')), findsOneWidget);

    await _sendShortcut(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('popup-input')), findsNothing);
    expect(find.text('打开弹层'), findsOneWidget);
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

  test('快捷键帮助显示真实重做和模块搜索', () {
    final hints = desktopShortcutHints(macOS: false);

    expect(hints.map((hint) => hint.action), contains('重做'));
    expect(
      hints.firstWhere((hint) => hint.action == '重做').keys,
      'Ctrl+Shift+Z',
    );
    expect(hints.firstWhere((hint) => hint.action == '当前页搜索').keys, 'Ctrl+F');
  });

  testWidgets('Windows 重做兼容 Ctrl+Y，新建、设置、保存均可用', (tester) async {
    final calls = <DesktopShortcutActionType>[];
    await tester
        .pumpWidget(_shortcutProbe(calls: calls, enabled: true, macOS: false));
    for (final key in [
      LogicalKeyboardKey.keyY,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.comma,
      LogicalKeyboardKey.enter
    ]) {
      await _sendShortcut(tester, key, control: true);
    }
    expect(calls, [
      DesktopShortcutActionType.redo,
      DesktopShortcutActionType.newItem,
      DesktopShortcutActionType.openSettings,
      DesktopShortcutActionType.saveForm
    ]);
  });

  testWidgets('输入框中可以保存表单和搜索，中文组词时所有命令让给输入法', (tester) async {
    final calls = <DesktopShortcutActionType>[];
    final controller = TextEditingController(text: '日记');
    addTearDown(controller.dispose);
    await tester.pumpWidget(_shortcutProbe(
        calls: calls, enabled: true, macOS: false, controller: controller));
    await _sendShortcut(tester, LogicalKeyboardKey.enter, control: true);
    await _sendShortcut(tester, LogicalKeyboardKey.keyN, control: true);
    expect(calls, [DesktopShortcutActionType.saveForm]);
    controller.value = const TextEditingValue(
        text: '输入中', composing: TextRange(start: 0, end: 3));
    await tester.pump();
    await _sendShortcut(tester, LogicalKeyboardKey.keyK, control: true);
    await _sendShortcut(tester, LogicalKeyboardKey.enter, control: true);
    await _sendShortcut(tester, LogicalKeyboardKey.escape);
    expect(calls, [DesktopShortcutActionType.saveForm]);
    expect(controller.text, '输入中');
  });

  testWidgets('页面宿主不遮住外层全局快捷键，Esc 可逐层冒泡', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: DesktopShortcutHost(
      enabled: true,
      macOS: false,
      pageScoped: false,
      onOpenSearch: () => calls.add('global'),
      onEscape: () {
        calls.add('popup');
        return true;
      },
      child: DesktopShortcutHost(
          enabled: true,
          macOS: false,
          onSearchPage: () => calls.add('page'),
          onEscape: () => false,
          child: const Focus(autofocus: true, child: SizedBox.expand())),
    )));
    await _sendShortcut(tester, LogicalKeyboardKey.keyK, control: true);
    await _sendShortcut(tester, LogicalKeyboardKey.keyF, control: true);
    await _sendShortcut(tester, LogicalKeyboardKey.escape);
    expect(calls, ['global', 'page', 'popup']);
  });

  testWidgets('无焦点的弹层也会阻止底下页面修改日程', (tester) async {
    var edits = 0;
    await tester.pumpWidget(MaterialApp(
        home: DesktopShortcutHost(
      enabled: true,
      macOS: false,
      onUndo: () => edits++,
      child: Focus(
          autofocus: true,
          child: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => showDialog<void>(
                            context: context,
                            requestFocus: false,
                            builder: (_) =>
                                const AlertDialog(title: Text('浮层'))),
                        child: const Text('打开')),
                  ))),
    )));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _sendShortcut(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(edits, 0);
  });

  testWidgets('保活页不可见时不响应，回到页面重新获得快捷键焦点', (tester) async {
    var active = true;
    var calls = 0;
    late StateSetter update;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return MainTabActivity(
          isActive: active,
          child: DesktopShortcutHost(
            enabled: true,
            macOS: false,
            autofocus: true,
            onNewItem: () => calls++,
            child: const SizedBox.expand(),
          ));
    })));
    await tester.pump();
    await _sendShortcut(tester, LogicalKeyboardKey.keyN, control: true);
    update(() => active = false);
    await tester.pump();
    await _sendShortcut(tester, LogicalKeyboardKey.keyN, control: true);
    update(() => active = true);
    await tester.pump();
    await tester.pump();
    await _sendShortcut(tester, LogicalKeyboardKey.keyN, control: true);
    expect(calls, 2);
  });

  testWidgets('重绑和停用实时生效，默认键不再触发', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = DesktopShortcutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    final calls = <DesktopShortcutActionType>[];
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider,
        child: _shortcutProbe(calls: calls, enabled: true, macOS: false)));
    final bindings = Map.of(provider.bindings);
    bindings[DesktopShortcutActionType.openSearch] = const DesktopKeyBinding(
        LogicalKeyboardKey.keyP,
        primary: true,
        shift: true);
    bindings[DesktopShortcutActionType.redo] = null;
    await provider.save(bindings);
    await tester.pump();
    await _sendShortcut(tester, LogicalKeyboardKey.keyK, control: true);
    await _sendShortcut(tester, LogicalKeyboardKey.keyY, control: true);
    await _sendShortcut(tester, LogicalKeyboardKey.keyP,
        control: true, shift: true);
    expect(calls, [DesktopShortcutActionType.openSearch]);
  });

  testWidgets('不可用命令不执行；滑块方向键不切日期', (tester) async {
    var calls = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(
        home: DesktopShortcutHost(
      enabled: true,
      macOS: false,
      onUndo: () => calls++,
      onNextDay: () => calls++,
      isAvailable: (action) => action != DesktopShortcutActionType.undo,
      child: Scaffold(
          body: Slider(focusNode: focus, value: 0.5, onChanged: (_) {})),
    )));
    focus.requestFocus();
    await tester.pump();
    await _sendShortcut(tester, LogicalKeyboardKey.arrowRight);
    await _sendShortcut(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(calls, 0);
  });
}
