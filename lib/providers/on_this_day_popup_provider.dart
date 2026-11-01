import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动时是否自动弹出「那年今日」。
///
/// 本机设置，独立于身份，不参与同步或备份。
/// 关闭后只是不再自动弹层，「记录回顾 → 那年今日」仍可手动查看。
class OnThisDayPopupProvider extends ChangeNotifier {
  OnThisDayPopupProvider({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferences = (preferencesLoader ?? SharedPreferences.getInstance)() {
    ready = _load();
  }

  static const storageKey = 'app_on_this_day_popup_v1';

  final Future<SharedPreferences> _preferences;
  late final Future<void> ready;
  bool _autoShow = true;
  bool _isLoaded = false;
  bool _disposed = false;

  /// 是否在打开 App 时自动弹出（默认开启，沿用旧行为）。
  bool get autoShow => _autoShow;
  bool get isLoaded => _isLoaded;

  Future<void> _load() async {
    try {
      final prefs = await _preferences;
      if (_disposed) return;
      _autoShow = prefs.getBool(storageKey) ?? true;
    } on Object {
      // 读失败按默认自动弹出，不阻塞界面
    } finally {
      if (!_disposed) {
        _isLoaded = true;
        notifyListeners();
      }
    }
  }

  Future<void> setAutoShow(bool value) async {
    if (_autoShow == value) return;
    final previous = _autoShow;
    _autoShow = value;
    notifyListeners();
    try {
      final prefs = await _preferences;
      final saved = await prefs.setBool(storageKey, value);
      if (!saved) throw StateError('保存「那年今日」自动弹出开关失败');
    } on Object {
      // 落盘失败要回滚，避免设置显示的和实际生效的不一致
      _autoShow = previous;
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
