import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/desktop_shortcut.dart';

/// 与身份无关的本机快捷键，不进入业务同步和 JSON 备份。
class DesktopShortcutProvider extends ChangeNotifier {
  DesktopShortcutProvider(
      {Future<SharedPreferences> Function()? preferencesLoader})
      : _preferences = (preferencesLoader ?? SharedPreferences.getInstance)() {
    ready = _load();
  }

  static const storageKey = 'desktop_shortcuts_v1';
  final Future<SharedPreferences> _preferences;
  late final Future<void> ready;
  Future<void> _saveQueue = Future.value();
  Map<DesktopShortcutActionType, DesktopKeyBinding?> _bindings =
      defaultDesktopBindings();
  bool _loaded = false;
  bool _disposed = false;

  bool get isLoaded => _loaded;
  Map<DesktopShortcutActionType, DesktopKeyBinding?> get bindings =>
      Map.unmodifiable(_bindings);

  Future<void> _load() async {
    try {
      final raw = (await _preferences).getString(storageKey);
      if (raw != null) {
        final json = jsonDecode(raw);
        if (json is Map) {
          final next = defaultDesktopBindings();
          for (final action in DesktopShortcutActionType.values) {
            if (!json.containsKey(action.name)) continue;
            final value = json[action.name];
            if (value == null) {
              next[action] = null;
            } else {
              final binding = DesktopKeyBinding.fromJson(value);
              if (binding == null) throw const FormatException('无效快捷键');
              next[action] = binding;
            }
          }
          // 损坏或相互冲突的偏好整体退回默认值，不覆盖文件。
          _validate(next);
          if (!_disposed) _bindings = next;
        }
      }
    } on Object {
      // 本机偏好异常不能阻止应用启动。
    } finally {
      if (!_disposed) {
        _loaded = true;
        notifyListeners();
      }
    }
  }

  static void _validate(
      Map<DesktopShortcutActionType, DesktopKeyBinding?> bindings) {
    if (bindings.length != DesktopShortcutActionType.values.length) {
      throw ArgumentError('快捷键设置缺少命令');
    }
    for (final entry in bindings.entries) {
      if (entry.value == null) continue;
      final error = validateDesktopBinding(entry.key, entry.value!, bindings);
      if (error != null) throw ArgumentError(error);
    }
  }

  Future<void> save(
      Map<DesktopShortcutActionType, DesktopKeyBinding?> bindings) {
    final next =
        Map<DesktopShortcutActionType, DesktopKeyBinding?>.unmodifiable(
            bindings);
    _validate(next);
    final operation = _saveQueue.then((_) async {
      await ready;
      if (_disposed || mapEquals(_bindings, next)) return;
      final prefs = await _preferences;
      try {
        final success = await prefs.setString(
            storageKey,
            jsonEncode({
              for (final entry in next.entries)
                entry.key.name: entry.value?.toJson(),
            }));
        if (!success) throw StateError('保存快捷键失败');
      } on Object {
        try {
          await prefs.reload();
        } on Object {/* 保留原始错误。 */}
        rethrow;
      }
      if (_disposed) return;
      _bindings = next;
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
