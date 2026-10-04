import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/models/main_tab_id.dart';
import 'package:time_manager/providers/main_tab_provider.dart';
import 'package:time_manager/screens/main_tab_settings_screen.dart';
import 'package:time_manager/theme/app_theme.dart';

import 'support/fake_main_tab_preferences_store.dart';

Finder _toggle(MainTabId tab) =>
    find.byKey(ValueKey('main-tab-switch-${tab.id}'));

Finder _row(MainTabId tab) => find.byKey(ValueKey('main-tab-row-${tab.id}'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<MainTabProvider> openSettings(
    WidgetTester tester, {
    Size size = const Size(360, 800),
    Brightness brightness = Brightness.light,
    TextScaler textScaler = TextScaler.noScaling,
    MainTabProvider? provider,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tabs = provider ?? MainTabProvider();
    if (provider == null) addTearDown(tabs.dispose);
    await tabs.ready;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(
        brightness,
        backgroundEnabled: true,
        surfaceOpacity: 0.4,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => MainTabSettingsScreen(provider: tabs),
                  )),
                  child: const Text('设置标签'),
                )),
      ),
    ));
    await tester.tap(find.text('设置标签'));
    await tester.pumpAndSettle();
    return tabs;
  }

  testWidgets('草稿开关可隐藏标签，返回取消，保存后重启恢复', (tester) async {
    final provider = await openSettings(tester);
    await tester.tap(_toggle(MainTabId.travel));
    await tester.pumpAndSettle();
    expect(provider.hiddenTabs, isEmpty);
    expect(tester.widget<Switch>(_toggle(MainTabId.travel)).value, isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(provider.hiddenTabs, isEmpty);

    await tester.tap(find.text('设置标签'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(_toggle(MainTabId.travel)).value, isTrue);
    await tester.tap(_toggle(MainTabId.travel));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.byType(MainTabSettingsScreen), findsNothing);
    final restored = MainTabProvider();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.hiddenTabs, {MainTabId.travel});
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败时保留草稿和原导航，显示错误后可重试', (tester) async {
    final provider = await openSettings(tester);
    final originalStore = SharedPreferencesStorePlatform.instance;
    final store = FakeMainTabPreferencesStore(rejectWrites: true);
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferencesStorePlatform.instance = originalStore);
    await tester.tap(_toggle(MainTabId.travel));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.text('保存标签设置失败，请重试'), findsOneWidget);
    expect(find.byType(MainTabSettingsScreen), findsOneWidget);
    expect(tester.widget<Switch>(_toggle(MainTabId.travel)).value, isFalse);
    expect(provider.hiddenTabs, isEmpty);
    store.rejectWrites = false;
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.byType(MainTabSettingsScreen), findsNothing);
    expect(provider.hiddenTabs, {MainTabId.travel});
    expect(tester.takeException(), isNull);
  });

  for (final input in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('$input 拖动手柄调整顺序并保存', (tester) async {
      final provider = await openSettings(
        tester,
        size: input == PointerDeviceKind.touch
            ? const Size(360, 800)
            : const Size(1200, 800),
      );
      final handle = find.byKey(const ValueKey('main-tab-drag-record'));
      final start = tester.getCenter(handle);
      final destination = tester.getCenter(_row(MainTabId.travel));
      final gesture = await tester.startGesture(start, kind: input);
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump();
      await gesture.moveTo(Offset(start.dx, destination.dy + 20));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_row(MainTabId.diary)).dy,
          lessThan(tester.getTopLeft(_row(MainTabId.record)).dy));
      expect(provider.order.first, MainTabId.record, reason: '保存前不改变导航');
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(provider.order.first, MainTabId.diary);
      expect(provider.order.indexOf(MainTabId.record), greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('菜单可上移下移，隐藏项再次显示时保留位置，恢复默认需保存', (tester) async {
    final provider = await openSettings(tester);
    await tester.tap(find.byTooltip('调整顺序：记录'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<PopupMenuItem<int>>(find.widgetWithText(
              PopupMenuItem<int>,
              '上移',
            ))
            .enabled,
        isFalse);
    await tester.tap(find.text('下移'));
    await tester.pumpAndSettle();
    await tester.tap(_toggle(MainTabId.record));
    await tester.pumpAndSettle();
    await tester.tap(_toggle(MainTabId.record));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(provider.order.take(2), [MainTabId.diary, MainTabId.record]);
    expect(provider.hiddenTabs, isEmpty);

    await tester.tap(find.text('设置标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(provider.order.first, MainTabId.diary);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(provider.order, MainTabId.values);
  });

  testWidgets('保留我的和至少一个其他标签，重新显示后可继续隐藏', (tester) async {
    await openSettings(tester);
    for (final tab in [
      MainTabId.diary,
      MainTabId.travel,
      MainTabId.checkIn,
      MainTabId.target,
    ]) {
      await tester.ensureVisible(_toggle(tab));
      await tester.tap(_toggle(tab));
      await tester.pumpAndSettle();
    }
    expect(tester.widget<Switch>(_toggle(MainTabId.record)).onChanged, isNull);
    await tester.ensureVisible(_toggle(MainTabId.profile));
    expect(tester.widget<Switch>(_toggle(MainTabId.profile)).value, isTrue);
    expect(tester.widget<Switch>(_toggle(MainTabId.profile)).onChanged, isNull);
    await tester.ensureVisible(_toggle(MainTabId.diary));
    await tester.tap(_toggle(MainTabId.diary));
    await tester.pumpAndSettle();
    expect(
        tester.widget<Switch>(_toggle(MainTabId.record)).onChanged, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('$brightness 窄屏、大字和壁纸下不溢出', (tester) async {
      await openSettings(
        tester,
        size: const Size(320, 640),
        brightness: brightness,
        textScaler: const TextScaler.linear(2),
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        _toggle(MainTabId.profile),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final card = tester.widget<Card>(_row(MainTabId.profile));
      expect(card.color!.a, closeTo(0.4, 0.01));
      expect(find.text('保存设置').hitTestable(), findsOneWidget);
    });
  }
}
