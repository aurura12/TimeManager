import 'package:shared_preferences/shared_preferences.dart';

class TravelLocalStore {
  static const String _draftKey = 'travel_records_draft';

  static Future<String?> loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_draftKey);
  }

  /// 保存成功返回 true；写入失败（磁盘、权限等）返回 false，调用方必须提示用户。
  static Future<bool> saveDraft(String markdown) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(_draftKey, markdown);
    } catch (_) {
      // 平台通道异常与写入返回 false 一样按失败处理，调用方负责提示。
      return false;
    }
  }
}
