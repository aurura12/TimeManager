import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/theme/app_tokens.dart';

import 'support/fake_main_tab_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认保持底部导航，左侧布局默认展开事件栏，重启与切身份保留偏好', () async {
    final provider = DesktopLayoutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    expect(provider.navigationLayout, DesktopNavigationLayout.bottom);
    expect(provider.categoryPanelWidth, AppSizes.categoryPanelMinWidth);
    await provider.setNavigationLayout(DesktopNavigationLayout.side);
    expect(
        provider.categoryPanelWidth, AppSizes.desktopCategoryPanelDefaultWidth);
    await provider.setCategoryPanelWidth(380);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('schedule_user_kind', 'j');
    final restored = DesktopLayoutProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.navigationLayout, DesktopNavigationLayout.side);
    expect(restored.categoryPanelWidth, 380);
    expect(
        prefs.getKeys().where((key) => key.startsWith('identity_')), isEmpty);
    await provider.setNavigationLayout(DesktopNavigationLayout.bottom);
    expect(provider.categoryPanelWidth, 380);
    await provider.resetCategoryPanelWidth();
    expect(provider.categoryPanelWidth, AppSizes.categoryPanelMinWidth);
  });

  test('损坏或未知设置保持旧导航，有效宽度单独恢复并收敛到边界', () async {
    for (final raw in [
      '{broken',
      '[]',
      jsonEncode({'navigation': 'future'})
    ]) {
      SharedPreferences.setMockInitialValues(
          {DesktopLayoutProvider.storageKey: raw});
      final provider = DesktopLayoutProvider();
      await provider.ready;
      expect(provider.navigationLayout, DesktopNavigationLayout.bottom);
      expect(provider.categoryPanelWidth, AppSizes.categoryPanelMinWidth);
      provider.dispose();
    }
    SharedPreferences.setMockInitialValues({
      DesktopLayoutProvider.storageKey:
          jsonEncode({'navigation': 'side', 'categoryWidth': 10000}),
    });
    final provider = DesktopLayoutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    expect(provider.navigationLayout, DesktopNavigationLayout.side);
    expect(provider.categoryPanelWidth, AppSizes.categoryPanelMaxWidth);
    expect(
        () => provider.setCategoryPanelWidth(double.nan), throwsArgumentError);
    expect(() => provider.setCategoryPanelWidth(double.infinity),
        throwsArgumentError);
    await provider.setCategoryPanelWidth(-10);
    expect(provider.categoryPanelWidth, AppSizes.categoryPanelMinWidth);
  });

  test('同时切导航和调宽不会相互覆盖', () async {
    final provider = DesktopLayoutProvider();
    addTearDown(provider.dispose);
    await Future.wait([
      provider.setNavigationLayout(DesktopNavigationLayout.side),
      provider.setCategoryPanelWidth(320),
    ]);
    final restored = DesktopLayoutProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.navigationLayout, DesktopNavigationLayout.side);
    expect(restored.categoryPanelWidth, 320);
  });

  test('写盘失败保持原布局，重建不读失败缓存，后续保存可恢复', () async {
    final originalStore = SharedPreferencesStorePlatform.instance;
    final store = FakeMainTabPreferencesStore(rejectWrites: true);
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferencesStorePlatform.instance = originalStore);
    final provider = DesktopLayoutProvider();
    addTearDown(provider.dispose);
    await provider.ready;
    await expectLater(
        provider.setNavigationLayout(DesktopNavigationLayout.side),
        throwsStateError);
    expect(provider.navigationLayout, DesktopNavigationLayout.bottom);
    final restored = DesktopLayoutProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.navigationLayout, DesktopNavigationLayout.bottom);
    store.rejectWrites = false;
    await provider.setCategoryPanelWidth(300);
    await provider.setNavigationLayout(DesktopNavigationLayout.side);
    expect(provider.navigationLayout, DesktopNavigationLayout.side);
    expect(provider.categoryPanelWidth, 300);
  });
}
