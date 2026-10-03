import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/theme_color_sheet.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ThemeModeProvider> openSheet(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final provider = ThemeModeProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    await tester.pumpWidget(ListenableBuilder(
      listenable: provider,
      builder: (context, _) => MaterialApp(
        theme: AppTheme.themeFor(
          brightness,
          seedColor: provider.themeColor,
          backgroundEnabled: true,
          surfaceOpacity: 0.4,
        ),
        home: Scaffold(
          body: Builder(builder: (context) {
            return TextButton(
              onPressed: () => showThemeColorSheet(context, provider: provider),
              child: const Text('选择主题色'),
            );
          }),
        ),
      ),
    ));
    await tester.tap(find.text('选择主题色'));
    await tester.pumpAndSettle();
    return provider;
  }

  testWidgets('预设色仅在预览中变化，关闭后保留原主题', (tester) async {
    final provider = await openSheet(tester);
    final originalScheme = AppTheme.light().colorScheme;
    await tester.tap(find.widgetWithText(ChoiceChip, '天空蓝'));
    await tester.pumpAndSettle();

    final previewScheme =
        Theme.of(tester.element(find.text('配色预览'))).colorScheme;
    expect(previewScheme.primary, isNot(originalScheme.primary));
    expect(provider.themeColor, AppSemanticColors.brand);
    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor!.a,
      1,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(provider.themeColor, AppSemanticColors.brand);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(ThemeModeProvider.themeColorStorageKey), isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('$brightness 下应用预设色并保存到本机', (tester) async {
      final provider = await openSheet(tester, brightness: brightness);
      await tester.tap(find.widgetWithText(ChoiceChip, '薰衣紫'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('应用主题色'));
      await tester.tap(find.text('应用主题色'));
      await tester.pumpAndSettle();

      expect(find.text('配色预览'), findsNothing);
      expect(provider.themeColor, AppSemanticColors.lavender);
      final scheme = Theme.of(tester.element(find.text('选择主题色'))).colorScheme;
      final expectedScheme = AppTheme.themeFor(
        brightness,
        seedColor: AppSemanticColors.lavender,
      ).colorScheme;
      expect(scheme.primary, expectedScheme.primary);
      expect(scheme.primaryContainer, expectedScheme.primaryContainer);
      expect(scheme.brightness, brightness);

      final restored = ThemeModeProvider();
      addTearDown(restored.dispose);
      await restored.ready;
      expect(restored.themeColor, AppSemanticColors.lavender);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('无效自定义输入不能应用，8 位输入应用时丢弃透明度', (tester) async {
    final provider = await openSheet(tester);
    await tester.enterText(find.byType(TextField), 'ZZ345678');
    await tester.pumpAndSettle();
    expect(find.text('请输入合法的 6 位或 8 位十六进制色值'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(provider.themeColor, AppSemanticColors.brand);

    await tester.enterText(find.byType(TextField), '#80345678');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('应用主题色'));
    await tester.tap(find.text('应用主题色'));
    await tester.pumpAndSettle();
    expect(provider.themeColor, const Color(0xFF345678));
    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复默认绿也需要应用才会修改现有主题', (tester) async {
    SharedPreferences.setMockInitialValues({
      ThemeModeProvider.themeColorStorageKey:
          AppSemanticColors.lavender.toARGB32(),
    });
    final provider = await openSheet(tester);
    await tester.ensureVisible(find.text('恢复默认绿'));
    await tester.tap(find.text('恢复默认绿'));
    await tester.pumpAndSettle();
    expect(provider.themeColor, AppSemanticColors.lavender);
    await tester.ensureVisible(find.text('应用主题色'));
    await tester.tap(find.text('应用主题色'));
    await tester.pumpAndSettle();
    expect(provider.themeColor, AppSemanticColors.brand);
    expect(tester.takeException(), isNull);
  });
}
