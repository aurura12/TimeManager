import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_semantic_colors.dart';

/// 本机外观偏好，与业务数据和用户身份无关。
class ThemeModeProvider with ChangeNotifier {
  static const String _storageKey = 'app_theme_mode';
  static const String themeColorStorageKey = 'app_theme_color_v1';

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  Color _themeColor = AppSemanticColors.brand;
  Color get themeColor => _themeColor;

  final Future<SharedPreferences> _preferences;
  late final Future<void> ready;
  bool _disposed = false;

  ThemeModeProvider({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferences = (preferencesLoader ?? SharedPreferences.getInstance)() {
    ready = _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await _preferences;
      if (_disposed) return;

      _themeMode = switch (prefs.get(_storageKey)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      final rawColor = prefs.get(themeColorStorageKey);
      if (rawColor is int && rawColor >= 0 && rawColor < (1 << 32)) {
        _themeColor = AppSemanticColors.opaque(Color(rawColor));
      }
      notifyListeners();
    } on Object {
      // 外观偏好不可读时保留默认值，不阻止应用启动。
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await ready;
    if (_disposed || _themeMode == mode) return;

    _themeMode = mode;
    notifyListeners();
    final prefs = await _preferences;
    if (!await prefs.setString(_storageKey, _modeToString(mode))) {
      throw StateError('保存外观模式失败');
    }
  }

  Future<void> setThemeColor(Color color) async {
    await ready;
    final opaqueColor = AppSemanticColors.opaque(color);
    if (_disposed || _themeColor == opaqueColor) return;

    final prefs = await _preferences;
    if (!await prefs.setInt(themeColorStorageKey, opaqueColor.toARGB32())) {
      throw StateError('保存主题色失败');
    }
    if (_disposed) return;
    _themeColor = opaqueColor;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String _modeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}
