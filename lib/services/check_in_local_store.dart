import 'package:shared_preferences/shared_preferences.dart';

import '../models/check_in_document.dart';

class CheckInLocalStore {
  static const _draftKey = 'check_in_data_draft';

  static Future<void> saveDraft(CheckInDocument document) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftKey, document.toMarkdown());
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
