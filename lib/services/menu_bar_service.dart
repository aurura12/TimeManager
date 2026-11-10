import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生菜单栏控制器回传的状态快照。
@immutable
class MenuBarState {
  const MenuBarState({
    required this.enabled,
    required this.panelVisible,
    required this.mainWindowVisible,
    required this.supported,
    required this.launchAtLoginAvailable,
    required this.launchAtLogin,
    required this.launchAtLoginNeedsApproval,
  });

  factory MenuBarState.fromMap(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('菜单栏通道返回了非对象状态');
    }
    bool readBool(String key, {bool fallback = false}) {
      final value = raw[key];
      return value is bool ? value : fallback;
    }

    return MenuBarState(
      enabled: readBool('enabled'),
      panelVisible: readBool('panelVisible'),
      mainWindowVisible: readBool('mainWindowVisible', fallback: true),
      supported: readBool('supported'),
      launchAtLoginAvailable: readBool('launchAtLoginAvailable'),
      launchAtLogin: readBool('launchAtLogin'),
      launchAtLoginNeedsApproval: readBool('launchAtLoginNeedsApproval'),
    );
  }

  /// 通道不可用时的保守状态：普通窗口模式。
  static const unavailable = MenuBarState(
    enabled: false,
    panelVisible: false,
    mainWindowVisible: true,
    supported: false,
    launchAtLoginAvailable: false,
    launchAtLogin: false,
    launchAtLoginNeedsApproval: false,
  );

  final bool enabled;
  final bool panelVisible;
  final bool mainWindowVisible;
  final bool supported;
  final bool launchAtLoginAvailable;
  final bool launchAtLogin;
  final bool launchAtLoginNeedsApproval;
}

/// 菜单栏通道的统一入口。
///
/// 抽成接口是为了让测试注入 Fake，不必真的起一个 macOS 应用。
abstract class MenuBarService {
  Future<MenuBarState> getState();
  Future<MenuBarState> configure({required bool enabled});
  Future<MenuBarState> showPanel();
  Future<MenuBarState> hidePanel();
  Future<MenuBarState> showMainWindow();
  Future<MenuBarState> hideMainWindow();
  Future<MenuBarState> openSettings();
  Future<MenuBarState> setLaunchAtLogin(bool enabled);
  Future<void> openLoginItemsSettings();
  Future<void> quit();
  void setStateHandler(Future<dynamic> Function(MethodCall call)? handler);
  void clearStateHandler();
}

/// `time_manager/menu_bar` 的 MethodChannel 实现。
class MethodChannelMenuBarService implements MenuBarService {
  MethodChannelMenuBarService({
    MethodChannel channel = const MethodChannel('time_manager/menu_bar'),
    Duration timeout = const Duration(seconds: 2),
  })  : _channel = channel,
        _timeout = timeout;

  final MethodChannel _channel;
  final Duration _timeout;

  @override
  Future<MenuBarState> getState() => _invoke('getState');

  @override
  Future<MenuBarState> configure({required bool enabled}) =>
      _invoke('configure', <String, Object?>{'enabled': enabled});

  @override
  Future<MenuBarState> showPanel() => _invoke('showPanel');

  @override
  Future<MenuBarState> hidePanel() => _invoke('hidePanel');

  @override
  Future<MenuBarState> showMainWindow() => _invoke('showMainWindow');

  @override
  Future<MenuBarState> hideMainWindow() => _invoke('hideMainWindow');

  @override
  Future<MenuBarState> openSettings() => _invoke('openSettings');

  @override
  Future<MenuBarState> setLaunchAtLogin(bool enabled) => _invoke(
        'setLaunchAtLogin',
        <String, Object?>{'enabled': enabled},
      );

  @override
  Future<void> openLoginItemsSettings() async {
    await _channel.invokeMethod<void>('openLoginItemsSettings').timeout(_timeout);
  }

  @override
  Future<void> quit() async {
    await _channel.invokeMethod<void>('quit').timeout(_timeout);
  }

  @override
  void setStateHandler(Future<dynamic> Function(MethodCall call)? handler) {
    _channel.setMethodCallHandler(handler);
  }

  @override
  void clearStateHandler() {
    _channel.setMethodCallHandler(null);
  }

  Future<MenuBarState> _invoke(String method, [Object? arguments]) async {
    final raw = await _channel.invokeMethod<Object?>(method, arguments).timeout(_timeout);
    return MenuBarState.fromMap(raw);
  }
}
