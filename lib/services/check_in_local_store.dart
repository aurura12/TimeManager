import 'package:shared_preferences/shared_preferences.dart';

import '../models/check_in_document.dart';

class CheckInLocalStore {
  static const _draftKey = 'check_in_data_draft';

  /// 保存成功返回 true；写入失败（磁盘、权限等）返回 false，调用方必须提示用户。
  static Future<bool> saveDraft(CheckInDocument document) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.setString(_draftKey, document.toMarkdown());
  }

  static Future<CheckInDocument?> loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftKey);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return CheckInDocument.fromMarkdown(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey);
  }
}
