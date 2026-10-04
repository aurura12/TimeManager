import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/desktop_shortcut_provider.dart';
import 'package:time_manager/screens/desktop_shortcut_settings_screen.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/widgets/desktop_shortcut_host.dart';

Future<void> _keys(WidgetTester tester, LogicalKeyboardKey key,
    {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  const previewDirectory = String.fromEnvironment('SHORTCUT_UI_PREVIEW_DIR');
  const fontPath = String.fromEnvironment('SHORTCUT_UI_PREVIEW_FONT');
  setUpAll(() async {
    if (fontPath.isNotEmpty) {
      final loader = FontLoader('ShortcutPreview');
      loader.addFont(Future.value(
          ByteData.sublistView(await File(fontPath).readAsBytes())));
      await loader.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  Future<DesktopShortcutProvider> pump(WidgetTester tester,
      {ThemeData? theme, GlobalKey? boundary}) async {
    SharedPreferences.setMockInitialValues({});
    final provider = DesktopShortcutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: MaterialApp(
          theme: theme ?? AppTheme.light(),
          home: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                  builder: (_) => DesktopShortcutSettingsScreen(
                                      provider: provider, macOS: false)),
                            ),
                        child: const Text('打开设置')),
                  )),
          builder: (_, child) => RepaintBoundary(key: boundary, child: child!)),
    ));
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    return provider;
  }

  testWidgets('捕获按键提示冲突，修改在保存后生效，取消捕获不更改配置', (tester) async {
    final provider = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('shortcut-edit-openSearch')));
    await tester.pumpAndSettle();
    await _keys(tester, LogicalKeyboardKey.keyF);
    expect(find.textContaining('冲突'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '使用此按键'))
            .onPressed,
        isNull);
    await _keys(tester, LogicalKeyboardKey.keyP, shift: true);
    await tester.tap(find.text('使用此按键'));
    await tester.pumpAndSettle();
    expect(provider.bindings[DesktopShortcutActionType.openSearch],
        defaultDesktopBindings()[DesktopShortcutActionType.openSearch]);
    await tester.tap(find.byKey(const ValueKey('shortcut-edit-searchPage')));
    await tester.pumpAndSettle();
    await _keys(tester, LogicalKeyboardKey.keyR);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(
        provider.bindings[DesktopShortcutActionType.openSearch],
        const DesktopKeyBinding(LogicalKeyboardKey.keyP,
            primary: true, shift: true));
    expect(provider.bindings[DesktopShortcutActionType.searchPage],
        defaultDesktopBindings()[DesktopShortcutActionType.searchPage]);
    expect(find.text('打开设置'), findsOneWidget);
  });

  testWidgets('打开设置后直接用快捷键保存，不需要先点击按钮取得焦点', (tester) async {
    await pump(tester);
    await _keys(tester, LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopShortcutSettingsScreen), findsNothing);
    expect(find.text('打开设置'), findsOneWidget);
  });

  testWidgets('捕获后用 Tab 和 Enter 选择取消，不会误确认新组合键', (tester) async {
    final provider = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('shortcut-edit-openSearch')));
    await tester.pumpAndSettle();
    await _keys(tester, LogicalKeyboardKey.keyP, shift: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Ctrl+K'), findsOneWidget);
    expect(provider.bindings[DesktopShortcutActionType.openSearch],
        defaultDesktopBindings()[DesktopShortcutActionType.openSearch]);
  });

  testWidgets('停用与恢复默认需要保存，关闭设置不会应用草稿', (tester) async {
    final provider = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('shortcut-toggle-openSearch')));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(provider.bindings[DesktopShortcutActionType.openSearch], isNotNull);
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shortcut-toggle-openSearch')));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(provider.bindings[DesktopShortcutActionType.openSearch], isNull);
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(provider.bindings, defaultDesktopBindings());
  });

  testWidgets('窄窗口、浅深主题和壁纸背景无溢出，捕获弹层不透明', (tester) async {
    addTearDown(tester.view.reset);
    for (final variant in ['light', 'dark', 'wallpaper', 'narrow']) {
      tester.view.physicalSize =
          variant == 'narrow' ? const Size(360, 640) : const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      final boundary = GlobalKey();
      var theme = variant == 'dark'
          ? AppTheme.dark()
          : AppTheme.light(backgroundEnabled: variant == 'wallpaper');
      if (fontPath.isNotEmpty) {
        final base = theme;
        theme = theme.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'ShortcutPreview'),
          primaryTextTheme:
              base.primaryTextTheme.apply(fontFamily: 'ShortcutPreview'),
          appBarTheme: base.appBarTheme.copyWith(
              titleTextStyle:
                  (base.appBarTheme.titleTextStyle ?? AppText.pageTitle)
                      .copyWith(fontFamily: 'ShortcutPreview')),
          listTileTheme: base.listTileTheme.copyWith(
            titleTextStyle: (base.listTileTheme.titleTextStyle ?? AppText.body)
                .copyWith(fontFamily: 'ShortcutPreview'),
            subtitleTextStyle:
                (base.listTileTheme.subtitleTextStyle ?? AppText.caption)
                    .copyWith(fontFamily: 'ShortcutPreview'),
          ),
          filledButtonTheme: FilledButtonThemeData(
              style: base.filledButtonTheme.style?.copyWith(
                  textStyle: WidgetStatePropertyAll(
                      AppText.button.copyWith(fontFamily: 'ShortcutPreview')))),
          outlinedButtonTheme: OutlinedButtonThemeData(
              style: base.outlinedButtonTheme.style?.copyWith(
                  textStyle: WidgetStatePropertyAll(
                      AppText.button.copyWith(fontFamily: 'ShortcutPreview')))),
          textButtonTheme: TextButtonThemeData(
              style: base.textButtonTheme.style?.copyWith(
                  textStyle: WidgetStatePropertyAll(
                      AppText.button.copyWith(fontFamily: 'ShortcutPreview')))),
        );
      }
      await pump(tester, theme: theme, boundary: boundary);
      expect(tester.takeException(), isNull);
      if (previewDirectory.isNotEmpty) {
        await tester.runAsync(() async {
          final render = boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(previewDirectory).create(recursive: true);
          await File('$previewDirectory/shortcuts_$variant.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(const ValueKey('shortcut-edit-openSearch')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final dialogTheme =
          Theme.of(tester.element(find.byType(AlertDialog))).dialogTheme;
      expect(dialogTheme.backgroundColor!.a, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }
  });
}
