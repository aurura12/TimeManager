import 'package:shared_preferences/shared_preferences.dart';

class TravelLocalStore {
  static const String _draftKey = 'travel_records_draft';

  static Future<String?> loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_draftKey);
  }

  static Future<void> saveDraft(String markdown) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftKey, markdown);
  }
}
