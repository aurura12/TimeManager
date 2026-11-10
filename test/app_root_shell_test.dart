import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/menu_bar_provider.dart';
import 'package:time_manager/services/menu_bar_service.dart';
import 'package:time_manager/widgets/app_root_shell.dart';
import 'package:time_manager/widgets/menu_bar_panel.dart';

MenuBarState _state({
  bool panelVisible = false,
  bool mainWindowVisible = false,
}) {
  return MenuBarState(
    enabled: true,
    panelVisible: panelVisible,
    mainWindowVisible: mainWindowVisible,
    supported: true,
    launchAtLoginAvailable: false,
    launchAtLogin: false,
    launchAtLoginNeedsApproval: false,
  );
}

class _ShellService implements MenuBarService {
  MenuBarState state = _state();
  Future<dynamic> Function(MethodCall call)? _handler;

  Future<void> emit(MenuBarState next) async {
    state = next;
    await _handler?.call(MethodCall('stateChanged', <String, Object?>{
      'enabled': next.enabled,
      'panelVisible': next.panelVisible,
      'mainWindowVisible': next.mainWindowVisible,
      'supported': next.supported,
      'launchAtLoginAvailable': next.launchAtLoginAvailable,
      'launchAtLogin': next.launchAtLogin,
      'launchAtLoginNeedsApproval': next.launchAtLoginNeedsApproval,
    }));
  }

  @override
  Future<MenuBarState> configure({required bool enabled}) async => state;

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
  void setStateHandler(Future<dynamic> Function(MethodCall call)? handler) {
    _handler = handler;
  }

  @override
  void clearStateHandler() {
    _handler = null;
  }
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static int builds = 0;

  @override
  void initState() {
    super.initState();
    builds++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _ProbeState.builds = 0;
  });

  Future<MenuBarProvider> buildProvider(_ShellService service) async {
    final provider = MenuBarProvider(service: service, macOSOverride: true);
    await provider.ready;
    return provider;
  }

  Future<void> pumpShell(
    WidgetTester tester,
    MenuBarProvider provider,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<MenuBarProvider?>.value(
        value: provider,
        child: const MaterialApp(
          home: AppRootShell(child: _Probe()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('主窗口隐藏时子界面仍在树上，只是不绘制', (tester) async {
    final provider = await buildProvider(_ShellService());
    await pumpShell(tester, provider);

    expect(provider.mainWindowVisible, isFalse);
    expect(find.byType(_Probe), findsNothing);
    expect(find.byType(_Probe, skipOffstage: false), findsOneWidget);
  });

  testWidgets('面板显示不重建主界面', (tester) async {
    final service = _ShellService();
    final provider = await buildProvider(service);
    await pumpShell(tester, provider);

    final state = tester.state<_ProbeState>(
      find.byType(_Probe, skipOffstage: false),
    );
    expect(_ProbeState.builds, 1);

    await service.emit(_state(panelVisible: true));
    await tester.pump();

    expect(find.byType(_Probe, skipOffstage: false), findsOneWidget);
    expect(
      tester.state<_ProbeState>(find.byType(_Probe, skipOffstage: false)),
      same(state),
    );
    expect(_ProbeState.builds, 1);
    expect(find.byType(MenuBarPanelView), findsOneWidget);
  });

  testWidgets('面板 400x560 下没有溢出', (tester) async {
    tester.view.physicalSize = const Size(400, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final service = _ShellService();
    final provider = await buildProvider(service);
    await pumpShell(tester, provider);
    await service.emit(_state(panelVisible: true));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('主窗口重新可见后面板让位', (tester) async {
    final service = _ShellService();
    final provider = await buildProvider(service);
    await pumpShell(tester, provider);

    await service.emit(_state(panelVisible: true));
    await tester.pump();
    await service.emit(_state(mainWindowVisible: true));
    await tester.pump();

    expect(find.byType(MenuBarPanelView), findsNothing);
    expect(find.byType(_Probe), findsOneWidget);
  });
}
