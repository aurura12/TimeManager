import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/screens/desktop_layout_settings_screen.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';

import 'support/fake_main_tab_preferences_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<DesktopLayoutProvider> openSettings(
    WidgetTester tester, {
    Size size = const Size(1000, 800),
    Brightness brightness = Brightness.light,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = DesktopLayoutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(brightness,
          backgroundEnabled: true, surfaceOpacity: 0.4),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: DesktopLayoutSettingsScreen(provider: provider),
    ));
    return provider;
  }

  testWidgets('选择两种导航立即持久化，事件栏可以恢复默认', (tester) async {
    final provider = await openSettings(tester);
    await tester.tap(find.text('左侧导航（宽屏布局）'));
    await tester.pumpAndSettle();
    expect(provider.navigationLayout, DesktopNavigationLayout.side);
    await provider.setCategoryPanelWidth(360);
    await tester.pump();
    await tester.tap(find.text('恢复事件栏默认宽度'));
    await tester.pumpAndSettle();
    expect(
        provider.categoryPanelWidth, AppSizes.desktopCategoryPanelDefaultWidth);
    await tester.tap(find.text('底部导航（原有布局）'));
    await tester.pumpAndSettle();
    final restored = DesktopLayoutProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.navigationLayout, DesktopNavigationLayout.bottom);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败显示可重试提示，原布局不变化', (tester) async {
    final provider = await openSettings(tester);
    final originalStore = SharedPreferencesStorePlatform.instance;
    final store = FakeMainTabPreferencesStore(rejectWrites: true);
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferencesStorePlatform.instance = originalStore);
    await tester.tap(find.text('左侧导航（宽屏布局）'));
    await tester.pumpAndSettle();
    expect(find.text('保存桌面布局失败，请重试'), findsOneWidget);
    expect(provider.navigationLayout, DesktopNavigationLayout.bottom);
    store.rejectWrites = false;
    await tester.tap(find.text('左侧导航（宽屏布局）'));
    await tester.pumpAndSettle();
    expect(provider.navigationLayout, DesktopNavigationLayout.side);
    expect(find.text('保存桌面布局失败，请重试'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('$brightness 窄窗口大字与壁纸布局无溢出', (tester) async {
      await openSettings(tester,
          size: const Size(360, 640),
          brightness: brightness,
          textScaler: TextScaler.linear(1.8));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('左侧导航（宽屏布局）'));
      await tester.tap(find.text('左侧导航（宽屏布局）'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
