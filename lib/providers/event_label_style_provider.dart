import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/event_label_style.dart';

/// 事件名显示偏好：本机设置，独立于身份，不参与业务同步或备份。
///
/// 只控制"一行还是两行"；无论选哪种，名字被截断时都能靠
/// 长按（手机）/ 悬停（桌面）看到完整名称。
class EventLabelStyleProvider extends ChangeNotifier {
  EventLabelStyleProvider({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferences = (preferencesLoader ?? SharedPreferences.getInstance)() {
    ready = _load();
  }

  static const storageKey = 'app_event_label_style_v1';

  final Future<SharedPreferences> _preferences;
  late final Future<void> ready;
  EventLabelStyle _style = EventLabelStyle.twoLines;
  bool _isLoaded = false;
  bool _disposed = false;

  EventLabelStyle get style => _style;
  bool get isLoaded => _isLoaded;

  Future<void> _load() async {
    try {
      final prefs = await _preferences;
      if (_disposed) return;
      _style = EventLabelStyle.fromId(prefs.getString(storageKey));
    } on Object {
      // 读失败按默认两行渲染，不阻塞界面
    } finally {
      if (!_disposed) {
        _isLoaded = true;
        notifyListeners();
      }
    }
  }

  Future<void> setStyle(EventLabelStyle style) async {
    if (_style == style) return;
    final previous = _style;
    _style = style;
    notifyListeners();
    try {
      final prefs = await _preferences;
      await prefs.setString(storageKey, style.id);
    } on Object {
      // 落盘失败要回滚显示，避免设置页显示的和实际生效的不一致
      _style = previous;
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
