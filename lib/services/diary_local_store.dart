import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/diary_gitee_config.dart';
import '../config/diary_github_config.dart';
import '../models/diary_kind.dart';
import '../models/remote_sync_platform.dart';
import 'remote_sync_settings.dart';
import 'app_user_identity_store.dart';

class DiaryLocalDraft {
  const DiaryLocalDraft({
    required this.kind,
    required this.date,
    required this.body,
    this.startedAt,
  });

  final DiaryKind kind;
  final DateTime date;
  final String body;
  final DateTime? startedAt;
}

/// 日记编辑器最近一次读取/写入的远端版本基线。
class DiaryRemoteBaseline {
  const DiaryRemoteBaseline({
    this.path,
    this.sha,
    required this.notFound,
  });

  final String? path;
  final String? sha;
  final bool notFound;
}

class DiaryLocalStore {
  static const String _githubTokenKey = 'diary_github_pat';
  static const String _giteeTokenKey = 'diary_gitee_pat';
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

  static String _draftPendingKey(DiaryKind kind, DateTime date) {
    return 'diary_draft_pending_${kind.code}_${_dateKey(date)}';
  }

  static String _baselineKey(DiaryKind kind, DateTime date) {
    return 'diary_remote_baseline_${kind.code}_${_dateKey(date)}';
  }

  static Future<String?> loadToken() async {
    final platform = await RemoteSyncSettings.loadPlatform();
    switch (platform) {
      case RemoteSyncPlatform.gitee:
        if (DiaryGiteeConfig.hasHardcodedToken) {
          return DiaryGiteeConfig.hardcodedToken.trim();
        }
        return _loadStoredToken(_giteeTokenKey);
      case RemoteSyncPlatform.github:
        if (DiaryGitHubConfig.hasHardcodedToken) {
          return DiaryGitHubConfig.hardcodedToken.trim();
        }
        return _loadStoredToken(_githubTokenKey);
    }
  }

  static Future<void> saveToken(String token) async {
    final platform = await RemoteSyncSettings.loadPlatform();
    switch (platform) {
      case RemoteSyncPlatform.gitee:
        if (DiaryGiteeConfig.hasHardcodedToken) return;
        await _secureStorage.write(key: _giteeTokenKey, value: token);
        return;
      case RemoteSyncPlatform.github:
        if (DiaryGitHubConfig.hasHardcodedToken) return;
        await _secureStorage.write(key: _githubTokenKey, value: token);
        return;
    }
  }

  static Future<String?> _loadStoredToken(String key) async {
    final secureToken = await _secureStorage.read(key: key);
    if (secureToken != null && secureToken.isNotEmpty) {
      return secureToken;
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyToken = prefs.getString(key);
    if (legacyToken != null && legacyToken.isNotEmpty) {
      await _secureStorage.write(key: key, value: legacyToken);
      await prefs.remove(key);
      return legacyToken;
    }
    return null;
  }

  static Future<DiaryKind> loadPreferredKind() async {
    final prefs = await SharedPreferences.getInstance();
    return DiaryKindX.fromCode(prefs.getString(_kindKey));
  }

  static Future<void> savePreferredKind(DiaryKind kind) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kindKey, kind.code);
  }

  static Future<DiaryKind?> loadManualKind() {
    return AppUserIdentityStore.loadManualKind();
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
    await prefs.setString(
      _draftStartKey(kind, date),
      startedAt.toIso8601String(),
    );
  }

  /// 标记一篇日记有本地修改，供同步中心执行真正的批量推送。
  static Future<void> markDraftPending(DiaryKind kind, DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_draftPendingKey(kind, date), true);
  }

  static Future<bool> isDraftPending(DiaryKind kind, DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_draftPendingKey(kind, date)) == true;
  }

  static Future<void> clearDraftPending(DiaryKind kind, DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftPendingKey(kind, date));
  }

  /// 列出当前身份中明确标记为待上传且非空的本地草稿。
  ///
  /// 仅有历史本地草稿、没有发生过待同步编辑标记时，不应因为点击同步中心
  /// 就自动创建远端文件；用户仍可在日记页主动点击“推送”。
  static Future<List<DiaryLocalDraft>> loadDrafts({
    required DiaryKind kind,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'diary_draft_${kind.code}_';
    final drafts = <DiaryLocalDraft>[];
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(prefix) || key.length != prefix.length + 8) {
        continue;
      }
      final body = prefs.getString(key);
      if (body == null || body.trim().isEmpty) continue;
      final rawDate = key.substring(prefix.length);
      final date = _parseCompactDate(rawDate);
      if (date == null) continue;
      if (prefs.getBool(_draftPendingKey(kind, date)) != true) continue;
      drafts.add(
        DiaryLocalDraft(
          kind: kind,
          date: date,
          body: body,
          startedAt: await loadDraftStartedAt(kind, date),
        ),
      );
    }
    drafts.sort((a, b) => b.date.compareTo(a.date));
    return drafts;
  }

  static DateTime? _parseCompactDate(String value) {
    if (!RegExp(r'^\d{8}$').hasMatch(value)) return null;
    final year = int.parse(value.substring(0, 4));
    final month = int.parse(value.substring(4, 6));
    final day = int.parse(value.substring(6, 8));
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  static Future<DiaryRemoteBaseline?> loadRemoteBaseline(
    DiaryKind kind,
    DateTime date,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_baselineKey(kind, date));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final notFound = decoded['notFound'] == true;
      return DiaryRemoteBaseline(
        path: decoded['path']?.toString(),
        sha: decoded['sha']?.toString(),
        notFound: notFound,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveRemoteBaseline(
    DiaryKind kind,
    DateTime date, {
    required String? path,
    required String? sha,
    required bool notFound,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _baselineKey(kind, date),
      jsonEncode({
        'path': path,
        'sha': sha,
        'notFound': notFound,
      }),
    );
  }

  static Future<void> removeRemoteBaseline(
    DiaryKind kind,
    DateTime date,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_baselineKey(kind, date));
  }
}
