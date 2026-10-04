import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_tokens.dart';

enum DesktopNavigationLayout { bottom, side }

/// 桌面布局仅存本机，不随身份切换，也不进入同步或业务备份。
class DesktopLayoutProvider extends ChangeNotifier {
  DesktopLayoutProvider({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferences = (preferencesLoader ?? SharedPreferences.getInstance)() {
    ready = _load();
  }

  static const storageKey = 'desktop_layout_v1';

  final Future<SharedPreferences> _preferences;
  late final Future<void> ready;
  Future<void> _saveQueue = Future<void>.value();
  DesktopNavigationLayout _navigationLayout = DesktopNavigationLayout.bottom;
  double? _categoryPanelWidth;
  bool _isLoaded = false;
  bool _disposed = false;

  bool get isLoaded => _isLoaded;
  DesktopNavigationLayout get navigationLayout => _navigationLayout;
  double get categoryPanelWidth =>
      _categoryPanelWidth ??
      (_navigationLayout == DesktopNavigationLayout.side
          ? AppSizes.desktopCategoryPanelDefaultWidth
          : AppSizes.categoryPanelMinWidth);

  Future<void> _load() async {
    try {
      final prefs = await _preferences;
      if (_disposed) return;
      final raw = prefs.get(storageKey);
      if (raw is String) {
        final document = jsonDecode(raw);
        if (document is Map<String, dynamic>) {
          if (document['navigation'] == DesktopNavigationLayout.side.name) {
            _navigationLayout = DesktopNavigationLayout.side;
          }
          final width = document['categoryWidth'];
          if (width is num && width.isFinite) {
            _categoryPanelWidth = _clampWidth(width.toDouble());
          }
        }
      }
    } on Object {
      // 损坏的偏好不阻止启动，保持原有布局。
    } finally {
      if (!_disposed) {
        _isLoaded = true;
        notifyListeners();
      }
    }
  }

  static double _clampWidth(double width) => width
      .clamp(AppSizes.categoryPanelMinWidth, AppSizes.categoryPanelMaxWidth)
      .toDouble();

  Future<void> setNavigationLayout(DesktopNavigationLayout layout) =>
      _update(navigationLayout: layout);

  Future<void> setCategoryPanelWidth(double width) {
    if (!width.isFinite) throw ArgumentError.value(width, 'width');
    return _update(categoryPanelWidth: _clampWidth(width));
  }

  Future<void> resetCategoryPanelWidth() => _update(resetWidth: true);

  Future<void> _update({
    DesktopNavigationLayout? navigationLayout,
    double? categoryPanelWidth,
    bool resetWidth = false,
  }) {
    final operation = _saveQueue.then((_) async {
      await ready;
      if (_disposed) return;
      // 在队列执行时读取另一项，避免同时切布局和调宽互相覆盖。
      final nextLayout = navigationLayout ?? _navigationLayout;
      final nextWidth =
          resetWidth ? null : categoryPanelWidth ?? _categoryPanelWidth;
      if (nextLayout == _navigationLayout && nextWidth == _categoryPanelWidth) {
        return;
      }
      final prefs = await _preferences;
      try {
        final saved = await prefs.setString(
          storageKey,
          jsonEncode({
            'navigation': nextLayout.name,
            'categoryWidth': nextWidth,
          }),
        );
        if (!saved) throw StateError('保存桌面布局失败');
      } on Object {
        try {
          await prefs.reload();
        } on Object {
          // 保留原始保存错误。
        }
        rethrow;
      }
      if (_disposed) return;
      _navigationLayout = nextLayout;
      _categoryPanelWidth = nextWidth;
      notifyListeners();
    });
    _saveQueue = operation.catchError((Object _) {});
    return operation;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
