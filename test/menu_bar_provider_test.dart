import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/menu_bar_provider.dart';
import 'package:time_manager/services/menu_bar_service.dart';

const _enabledState = MenuBarState(
  enabled: true,
  panelVisible: false,
  mainWindowVisible: false,
  supported: true,
  launchAtLoginAvailable: true,
  launchAtLogin: false,
  launchAtLoginNeedsApproval: false,
);

MenuBarState _state({
  bool enabled = true,
  bool panelVisible = false,
  bool mainWindowVisible = false,
  bool launchAtLogin = false,
  bool needsApproval = false,
}) {
  return MenuBarState(
    enabled: enabled,
    panelVisible: panelVisible,
    mainWindowVisible: mainWindowVisible,
    supported: true,
    launchAtLoginAvailable: true,
    launchAtLogin: launchAtLogin,
    launchAtLoginNeedsApproval: needsApproval,
  );
}

class _FakeMenuBarService implements MenuBarService {
  _FakeMenuBarService({MenuBarState initial = _enabledState}) : state = initial;

  MenuBarState state;
  final List<String> calls = <String>[];
  bool failConfigure = false;
  bool failLaunchAtLogin = false;
  Future<dynamic> Function(MethodCall call)? _handler;

  Future<void> emit(String method, [Object? arguments]) async {
    await _handler?.call(MethodCall(method, arguments));
  }

  @override
  Future<MenuBarState> configure({required bool enabled}) async {
    calls.add('configure:$enabled');
    if (failConfigure) throw PlatformException(code: 'boom');
    state = _state(
      enabled: enabled,
      mainWindowVisible: !enabled,
      launchAtLogin: state.launchAtLogin,
    );
    return state;
  }

  @override
  Future<MenuBarState> getState() async {
    calls.add('getState');
    return state;
  }

  @override
  Future<MenuBarState> hideMainWindow() async {
    calls.add('hideMainWindow');
    state = _state(enabled: true, launchAtLogin: state.launchAtLogin);
    return state;
  }

  @override
  Future<MenuBarState> hidePanel() async {
    calls.add('hidePanel');
    state = _state(enabled: state.enabled, launchAtLogin: state.launchAtLogin);
    return state;
  }

  @override
  Future<MenuBarState> openSettings() async {
    calls.add('openSettings');
    state = _state(
      enabled: state.enabled,
      mainWindowVisible: true,
      launchAtLogin: state.launchAtLogin,
    );
    return state;
  }

  @override
  Future<MenuBarState> setLaunchAtLogin(bool enabled) async {
    calls.add('setLaunchAtLogin:$enabled');
    if (failLaunchAtLogin) throw PlatformException(code: 'login_failed');
    state = _state(
      enabled: state.enabled,
      mainWindowVisible: state.mainWindowVisible,
      launchAtLogin: enabled,
    );
    return state;
  }

  @override
  Future<MenuBarState> showMainWindow() async {
    calls.add('showMainWindow');
    state = _state(
      enabled: state.enabled,
      mainWindowVisible: true,
      launchAtLogin: state.launchAtLogin,
    );
    return state;
  }

  @override
  Future<MenuBarState> showPanel() async {
    calls.add('showPanel');
    state = _state(
      enabled: state.enabled,
      panelVisible: true,
      launchAtLogin: state.launchAtLogin,
    );
    return state;
  }

  @override
  Future<void> openLoginItemsSettings() async {
    calls.add('openLoginItemsSettings');
  }

  @override
  Future<void> quit() async {
    calls.add('quit');
  }

  @override
  void setStateHandler(Future<dynamic> Function(MethodCall call)? handler) {
    _handler = handler;
  }

  @override
  void clearStateHandler() {
    _handler = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('默认开启并在启动时对账原生状态', () async {
    final service = _FakeMenuBarService();
    final provider = MenuBarProvider(
      service: service,
      macOSOverride: true,
    );
    await provider.ready;

    expect(provider.supported, isTrue);
    expect(provider.enabled, isTrue);
    expect(provider.mainWindowVisible, isFalse);
    expect(provider.isLoaded, isTrue);
    expect(service.calls, contains('configure:true'));
  });

  test('本机偏好关闭时启动传入 false', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MenuBarProvider.modeStorageKey: false,
    });
    final service = _FakeMenuBarService(initial: _state(enabled: false, mainWindowVisible: true));
    final provider = MenuBarProvider(service: service, macOSOverride: true);
    await provider.ready;

    expect(provider.enabled, isFalse);
    expect(service.calls, contains('configure:false'));
  });

  test('通道失败时回退为普通窗口并记录错误', () async {
    final service = _FakeMenuBarService()..failConfigure = true;
    final provider = MenuBarProvider(service: service, macOSOverride: true);
    await provider.ready;

    expect(provider.enabled, isFalse);
    expect(provider.mainWindowVisible, isTrue);
    expect(provider.lastError, isNotNull);
    expect(service.calls, contains('showMainWindow'));
  });

  test('非 macOS 不触碰通道', () async {
    final service = _FakeMenuBarService();
    final provider = MenuBarProvider(service: service, macOSOverride: false);
    await provider.ready;

    expect(provider.supported, isFalse);
    expect(provider.enabled, isFalse);
    expect(service.calls, isEmpty);
  });

  test('切换菜单栏模式会落盘偏好', () async {
    final service = _FakeMenuBarService();
    final provider = MenuBarProvider(service: service, macOSOverride: true);
    await provider.ready;

    await provider.setEnabled(false);

    expect(provider.enabled, isFalse);
    expect(provider.mainWindowVisible, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(MenuBarProvider.modeStorageKey), isFalse);
  });

  test('切换失败会回滚开关并回灌原生', () async {
    final service = _FakeMenuBarService();
    final provider = MenuBarProvider(service: service, macOSOverride: true);
    await provider.ready;
    service.failConfigure = true;

    await expectLater(provider.setEnabled(false), throwsA(isA<PlatformException>()));

    expect(provider.enabled, isTrue);
    expect(
      service.calls.where((call) => call.startsWith('configure:')).toList(),
      ['configure:true', 'configure:false', 'configure:true'],
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(MenuBarProvider.modeStorageKey), isNull);
  });

  test('登录项失败会回滚并抛出', () async {
    final service = _FakeMenuBarService()..failLaunchAtLogin = true;
    final provider = MenuBarProvider(service: service, macOSOverride: true);
    await provider.ready;

    await expectLater(
      provider.setLaunchAtLogin(true),
      throwsA(isA<PlatformException>()),
    );
    expect(provider.launchAtLogin, isFalse);
  });

  test('原生状态变化会同步到 Provider', () async {
    final service = _FakeMenuBarService();
    final provider = MenuBarProvider(service: service, macOSOverride: true);
    await provider.ready;

    await service.emit('stateChanged', <String, Object?>{
      'enabled': true,
      'panelVisible': true,
      'mainWindowVisible': false,
      'supported': true,
      'launchAtLoginAvailable': true,
      'launchAtLogin': false,
      'launchAtLoginNeedsApproval': false,
    });

    expect(provider.panelVisible, isTrue);
    expect(provider.isMainSurfaceActive, isFalse);
  });

  test('原生请求退出时先落盘再退出', () async {
    final service = _FakeMenuBarService();
    final provider = MenuBarProvider(service: service, macOSOverride: true);
    await provider.ready;
    var flushed = false;
    provider.onQuitRequested = () async {
      flushed = true;
    };

    await service.emit('quitRequested');
    await Future<void>.delayed(Duration.zero);

    expect(flushed, isTrue);
    expect(service.calls, contains('quit'));
  });
}
