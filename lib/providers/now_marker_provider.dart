import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录页「当前时刻」小圆点的显示偏好。
///
/// 本机设置，独立于身份，不参与同步或备份。
class NowMarkerProvider extends ChangeNotifier {
  NowMarkerProvider({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferences = (preferencesLoader ?? SharedPreferences.getInstance)() {
    ready = _load();
  }

  static const storageKey = 'app_now_marker_v1';

  final Future<SharedPreferences> _preferences;
  late final Future<void> ready;
  bool _enabled = true;
  bool _isLoaded = false;
  bool _disposed = false;

  bool get enabled => _enabled;
  bool get isLoaded => _isLoaded;

  Future<void> _load() async {
    try {
      final prefs = await _preferences;
      if (_disposed) return;
      _enabled = prefs.getBool(storageKey) ?? true;
    } on Object {
      // 读失败按默认显示，不阻塞界面
    } finally {
      if (!_disposed) {
        _isLoaded = true;
        notifyListeners();
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    final previous = _enabled;
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await _preferences;
      final saved = await prefs.setBool(storageKey, value);
      if (!saved) throw StateError('保存「现在」标记开关失败');
    } on Object {
      // 落盘失败要回滚，避免设置显示的和实际生效的不一致
      _enabled = previous;
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
