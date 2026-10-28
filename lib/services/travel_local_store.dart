import 'package:shared_preferences/shared_preferences.dart';

class TravelLocalStore {
  static const String _draftKey = 'travel_records_draft';
  static Future<void> _operationTail = Future<void>.value();

  /// 读写串行，避免读取到尚未确认落盘的偏好缓存，也避免失败回滚覆盖后续写入。
  static Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static Future<String?> loadDraft() => _serialized(() async {
        final prefs = await SharedPreferences.getInstance();
        return prefs.getString(_draftKey);
      });

  /// 保存成功返回 true；写入失败（磁盘、权限等）返回 false，调用方必须提示用户。
  static Future<bool> saveDraft(String markdown) => _serialized(() async {
        SharedPreferences prefs;
        try {
          prefs = await SharedPreferences.getInstance();
        } catch (_) {
          return false;
        }
        String? previous;
        try {
          previous = prefs.getString(_draftKey);
        } catch (_) {
          return false;
        }
        try {
          if (await prefs.setString(_draftKey, markdown)) return true;
        } catch (_) {
          // 平台通道异常与写入返回 false 一样按失败处理。
        }

        // SharedPreferences 在尝试写入前就会修改进程内缓存。恢复这个键，
        // 否则同步中心会把一个已报告失败的删除当成有效墓碑推到远端。
        // 即使恢复写盘也失败，setString/remove 仍会先把缓存改回旧值。
        try {
          if (previous == null) {
            await prefs.remove(_draftKey);
          } else {
            await prefs.setString(_draftKey, previous);
          }
        } catch (_) {
          // 缓存已恢复；原始写入依然向调用方报告失败。
        }
        return false;
      });
}
