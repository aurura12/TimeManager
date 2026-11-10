import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_log_service.dart';
import '../services/menu_bar_service.dart';
import '../utils/platform_features.dart';

/// macOS 菜单栏常驻的本机状态。
///
/// 原生是窗口可见性的权威（点图标、点外部、关窗都由原生发起），
/// 这里保存一份镜像供界面使用，并把用户偏好落到本机。
/// 与身份无关，不进同步或备份。
class MenuBarProvider extends ChangeNotifier {
  MenuBarProvider({
    MenuBarService? service,
    Future<SharedPreferences> Function()? preferencesLoader,
    bool? macOSOverride,
  })  : _service = service ?? MethodChannelMenuBarService(),
        _isMacOS = macOSOverride ?? Platform.isMacOS,
        _preferences = (preferencesLoader ?? SharedPreferences.getInstance)() {
    ready = _load();
  }

  static const modeStorageKey = 'app_menu_bar_mode_v1';

  final MenuBarService _service;
  final bool _isMacOS;
  final Future<SharedPreferences> _preferences;
  late final Future<void> ready;

  bool _supported = false;
  bool _enabled = true;
  bool _panelVisible = false;
  bool _mainWindowVisible = true;
  bool _launchAtLoginAvailable = false;
  bool _launchAtLogin = false;
  bool _launchAtLoginNeedsApproval = false;
  bool _isLoaded = false;
  bool _disposed = false;
  String? _lastError;

  /// 「退出」前让业务侧落盘；main.dart 注入。
  Future<void> Function()? onQuitRequested;

  bool get supported => _supported;
  bool get enabled => _enabled;
  bool get panelVisible => _panelVisible;
  bool get mainWindowVisible => _mainWindowVisible;
  bool get launchAtLoginAvailable => _launchAtLoginAvailable;
  bool get launchAtLogin => _launchAtLogin;
  bool get launchAtLoginNeedsApproval => _launchAtLoginNeedsApproval;
  bool get isLoaded => _isLoaded;
  String? get lastError => _lastError;

  /// 主界面是否是当前可交互的表面。
  ///
  /// 面板或「只有图标」状态下，快捷键和「那年今日」自动弹层都必须让位。
  bool get isMainSurfaceActive => !_supported || !_enabled || _mainWindowVisible;

  Future<void> _load() async {
    if (!supportsMenuBarFor(macos: _isMacOS)) {
      _supported = false;
      _enabled = false;
      _isLoaded = true;
      notifyListeners();
      return;
    }

    _supported = true;
    var desired = true;
    try {
      final prefs = await _preferences;
      desired = prefs.getBool(modeStorageKey) ?? true;
    } on Object {
      // 读不到偏好就按默认开启，不能因为偏好文件坏了不启动。
    }
    if (_disposed) return;

    _service.setStateHandler(_handleNativeCall);
    try {
      final state = await _service.configure(enabled: desired);
      _apply(state);
    } on Object catch (error, stackTrace) {
      _lastError = '菜单栏模式启动失败：$error';
      AppLogService.instance.error(
        '菜单栏模式初始化失败，已回退为普通窗口',
        source: 'menu_bar',
        error: error,
        stackTrace: stackTrace,
      );
      _enabled = false;
      _mainWindowVisible = true;
      try {
        // 只调用不采信返回值：通道可能回一份「仍开启」的旧状态，
        // 会把这里的回退覆盖掉。
        await _service.showMainWindow();
      } on Object {
        // 通道整体不可用时无法兜底，至少保证界面可用。
      }
    } finally {
      if (!_disposed) {
        _isLoaded = true;
        notifyListeners();
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    if (!_supported || _enabled == value) return;
    final previous = _enabled;
    _enabled = value;
    _lastError = null;
    notifyListeners();
    try {
      _applyAndNotify(await _service.configure(enabled: value));
      final prefs = await _preferences;
      final saved = await prefs.setBool(modeStorageKey, value);
      if (!saved) throw StateError('保存菜单栏设置失败');
    } on Object {
      _enabled = previous;
      notifyListeners();
      try {
        _apply(await _service.configure(enabled: previous));
      } on Object {
        // 回滚写不回去时保持本地旧值，下一次设置仍会重试。
      }
      rethrow;
    }
  }

  Future<void> setLaunchAtLogin(bool value) async {
    if (!_supported || !_launchAtLoginAvailable || _launchAtLogin == value) {
      return;
    }
    final previous = _launchAtLogin;
    _launchAtLogin = value;
    _lastError = null;
    notifyListeners();
    try {
      _applyAndNotify(await _service.setLaunchAtLogin(value));
    } on Object {
      _launchAtLogin = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> showPanel() async {
    if (!_supported) return;
    _applyAndNotify(await _service.showPanel());
  }

  Future<void> hidePanel() async {
    if (!_supported) return;
    _applyAndNotify(await _service.hidePanel());
  }

  Future<void> openMainWindow() async {
    if (!_supported) return;
    _applyAndNotify(await _service.showMainWindow());
  }

  Future<void> openSettings() async {
    if (!_supported) return;
    _applyAndNotify(await _service.openSettings());
  }

  Future<void> openLoginItemsSettings() async {
    if (!_supported) return;
    await _service.openLoginItemsSettings();
  }

  /// 面板上的「退出」：先落盘，再终止。与状态栏菜单走同一条路径。
  Future<void> requestQuit() async {
    if (!_supported) return;
    await _flushAndQuit();
  }

  /// 登录项失败的可读原因，交给设置页提示。
  String describeLaunchAtLoginError(Object error) {
    if (error is PlatformException) {
      return error.message?.trim().isNotEmpty == true
          ? error.message!.trim()
          : '系统拒绝了登录项设置';
    }
    return '设置登录项失败，请稍后重试';
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (_disposed) return null;
    switch (call.method) {
      case 'stateChanged':
        _apply(MenuBarState.fromMap(call.arguments));
        notifyListeners();
      case 'quitRequested':
        unawaited(_flushAndQuit());
    }
    return null;
  }

  Future<void> _flushAndQuit() async {
    try {
      await onQuitRequested?.call();
    } on Object catch (error, stackTrace) {
      AppLogService.instance.error(
        '退出前落盘失败',
        source: 'menu_bar',
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      await _service.quit();
    } on Object {
      // 原生还有 3 秒兜底强退，这里失败不再重试。
    }
  }

  void _applyAndNotify(MenuBarState state) {
    _apply(state);
    if (!_disposed) notifyListeners();
  }

  void _apply(MenuBarState state) {
    _supported = state.supported;
    _enabled = state.enabled;
    _panelVisible = state.panelVisible;
    _mainWindowVisible = state.mainWindowVisible;
    _launchAtLoginAvailable = state.launchAtLoginAvailable;
    _launchAtLogin = state.launchAtLogin;
    _launchAtLoginNeedsApproval = state.launchAtLoginNeedsApproval;
  }

  @override
  void dispose() {
    _disposed = true;
    _service.clearStateHandler();
    super.dispose();
  }
}
