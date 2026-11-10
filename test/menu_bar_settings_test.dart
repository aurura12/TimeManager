import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/menu_bar_provider.dart';
import 'package:time_manager/services/menu_bar_service.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/menu_bar_settings_tiles.dart';

MenuBarState _state({
  bool enabled = true,
  bool launchAtLoginAvailable = true,
}) {
  return MenuBarState(
    enabled: enabled,
    panelVisible: false,
    mainWindowVisible: !enabled,
    supported: true,
    launchAtLoginAvailable: launchAtLoginAvailable,
    launchAtLogin: false,
    launchAtLoginNeedsApproval: false,
  );
}

class _SettingsService implements MenuBarService {
  _SettingsService({MenuBarState? initial}) : state = initial ?? _state();

  MenuBarState state;
  bool failConfigure = false;

  @override
  Future<MenuBarState> configure({required bool enabled}) async {
    if (failConfigure) throw PlatformException(code: 'boom');
    state = _state(
      enabled: enabled,
      launchAtLoginAvailable: state.launchAtLoginAvailable,
    );
    return state;
  }

  @override
  Future<MenuBarState> getState() async => state;

  @override
  Future<MenuBarState> showPanel() async => state;

  @override
  Future<MenuBarState> hidePanel() async => state;

  @override
  Future<MenuBarState> showMainWindow() async => state;

  @override
  Future<MenuBarState> hideMainWindow() async => state;

  @override
  Future<MenuBarState> openSettings() async => state;

  @override
  Future<MenuBarState> setLaunchAtLogin(bool enabled) async => state;

  @override
  Future<void> openLoginItemsSettings() async {}

  @override
  Future<void> quit() async {}

  @override
  void setStateHandler(Future<dynamic> Function(MethodCall call)? handler) {}

  @override
  void clearStateHandler() {}
}

Future<MenuBarProvider> _provider(
  WidgetTester tester, {
  _SettingsService? service,
  bool macOS = true,
}) async {
  final provider = MenuBarProvider(
    service: service ?? _SettingsService(),
    macOSOverride: macOS,
  );
  await provider.ready;
  return provider;
}

Future<void> _pump(
  WidgetTester tester,
  MenuBarProvider provider,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MenuBarProvider?>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(child: MenuBarSettingsTiles()),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('有菜单栏能力时显示两个开关', (tester) async {
    final provider = await _provider(tester);
    await _pump(tester, provider);

    expect(find.text('菜单栏常驻'), findsOneWidget);
    expect(find.text('登录时自动启动'), findsOneWidget);
    expect(find.text('启动后只显示菜单栏图标，点图标查看今日速览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('macOS 13 以下隐藏登录项开关', (tester) async {
    final provider = await _provider(
      tester,
      service: _SettingsService(initial: _state(launchAtLoginAvailable: false)),
    );
    await _pump(tester, provider);

    expect(find.text('菜单栏常驻'), findsOneWidget);
    expect(find.text('登录时自动启动'), findsNothing);
  });

  testWidgets('非 macOS 或缺少 Provider 时不渲染', (tester) async {
    final provider = await _provider(tester, macOS: false);
    await _pump(tester, provider);
    expect(find.text('菜单栏常驻'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: MenuBarSettingsTiles()),
      ),
    );
    await tester.pump();
    expect(find.text('菜单栏常驻'), findsNothing);
  });

  testWidgets('切换失败时回滚并提示', (tester) async {
    final service = _SettingsService();
    final provider = await _provider(tester, service: service);
    await _pump(tester, provider);
    service.failConfigure = true;

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    expect(provider.enabled, isTrue);
    expect(find.text('切换菜单栏模式失败，已恢复原设置'), findsOneWidget);
  });
}
