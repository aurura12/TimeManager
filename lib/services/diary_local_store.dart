import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/diary_github_config.dart';
import '../models/diary_kind.dart';

class DiaryLocalStore {
  static const String _tokenKey = 'diary_github_pat';
  static const String _kindKey = 'diary_preferred_kind';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static String _dateKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}$month$day';
  }

  static String _draftBodyKey(DiaryKind kind, DateTime date) {
    return 'diary_draft_${kind.code}_${_dateKey(date)}';
  }

  static String _draftStartKey(DiaryKind kind, DateTime date) {
    return 'diary_draft_start_${kind.code}_${_dateKey(date)}';
  }

  static Future<String?> loadToken() async {
    if (DiaryGitHubConfig.hasHardcodedToken) {
      return DiaryGitHubConfig.hardcodedToken.trim();
    }

    // 优先读安全存储；若存在旧版本 SharedPreferences 数据则自动迁移。
    final secureToken = await _secureStorage.read(key: _tokenKey);
    if (secureToken != null && secureToken.isNotEmpty) {
      return secureToken;
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyToken = prefs.getString(_tokenKey);
    if (legacyToken != null && legacyToken.isNotEmpty) {
      await _secureStorage.write(key: _tokenKey, value: legacyToken);
      await prefs.remove(_tokenKey);
      return legacyToken;
    }
    return null;
  }

  static Future<void> saveToken(String token) async {
    if (DiaryGitHubConfig.hasHardcodedToken) {
      return;
    }
    await _secureStorage.write(key: _tokenKey, value: token);
  }

  static Future<DiaryKind> loadPreferredKind() async {
    final prefs = await SharedPreferences.getInstance();
    return DiaryKindX.fromCode(prefs.getString(_kindKey));
  }

  static Future<void> savePreferredKind(DiaryKind kind) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kindKey, kind.code);
  }

  static Future<String?> loadDraftBody(DiaryKind kind, DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_draftBodyKey(kind, date));
  }

  static Future<void> saveDraftBody(
      DiaryKind kind, DateTime date, String body) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftBodyKey(kind, date), body);
  }

  static Future<DateTime?> loadDraftStartedAt(
      DiaryKind kind, DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftStartKey(kind, date));
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> saveDraftStartedAt(
      DiaryKind kind, DateTime date, DateTime startedAt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftStartKey(kind, date), startedAt.toIso8601String());
  }
}
