import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/diary_kind.dart';
import '../models/feishu_calendar_models.dart';

/// 飞书凭据与同步状态的本地存储。
///
/// 密钥类（App Secret / token）走系统钥匙串，非敏感状态走 SharedPreferences。
/// 所有键都按身份（g/j）显式拼，不用“当前身份”动态取值，避免同步途中切换身份
/// 把结果写到另一个人名下。
class FeishuCredentialStore {
  FeishuCredentialStore._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static String _secureKey(DiaryKind kind, String suffix) =>
      'feishu_${suffix}_${kind.code}';

  static String _prefKey(DiaryKind kind, String suffix) =>
      'identity_${kind.code}_feishu_$suffix';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  // --- 应用凭据 ---

  static Future<FeishuCredentials?> loadCredentials(DiaryKind kind) async {
    final appId = await _secure.read(key: _secureKey(kind, 'app_id'));
    final appSecret = await _secure.read(key: _secureKey(kind, 'app_secret'));
    if ((appId ?? '').trim().isEmpty || (appSecret ?? '').trim().isEmpty) {
      return null;
    }
    return FeishuCredentials(
        appId: appId!.trim(), appSecret: appSecret!.trim());
  }

  /// 保存凭据；换了 App ID 就说明换了一个应用，旧令牌必须作废。
  static Future<void> saveCredentials(
    DiaryKind kind,
    FeishuCredentials credentials,
  ) async {
    final previous = await loadCredentials(kind);
    await _secure.write(
      key: _secureKey(kind, 'app_id'),
      value: credentials.appId.trim(),
    );
    await _secure.write(
      key: _secureKey(kind, 'app_secret'),
      value: credentials.appSecret.trim(),
    );
    if (previous != null && previous.appId != credentials.appId.trim()) {
      await clearTokens(kind);
    }
  }

  static Future<void> clearCredentials(DiaryKind kind) async {
    await _secure.delete(key: _secureKey(kind, 'app_id'));
    await _secure.delete(key: _secureKey(kind, 'app_secret'));
    await clearTokens(kind);
  }

  // --- 令牌 ---

  static Future<FeishuTokenSet?> loadTokens(DiaryKind kind) async {
    final accessToken =
        await _secure.read(key: _secureKey(kind, 'access_token'));
    final accessExpiresAt =
        await _secure.read(key: _secureKey(kind, 'access_expires_at'));
    if ((accessToken ?? '').isEmpty || accessExpiresAt == null) return null;
    final accessMs = int.tryParse(accessExpiresAt);
    if (accessMs == null) return null;
    final refreshToken =
        await _secure.read(key: _secureKey(kind, 'refresh_token'));
    final refreshExpiresAt =
        await _secure.read(key: _secureKey(kind, 'refresh_expires_at'));
    final scope = await _secure.read(key: _secureKey(kind, 'scope'));
    final refreshMs = int.tryParse(refreshExpiresAt ?? '');
    return FeishuTokenSet(
      accessToken: accessToken!,
      accessExpiresAt: DateTime.fromMillisecondsSinceEpoch(accessMs),
      refreshToken: refreshToken,
      refreshExpiresAt: refreshMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(refreshMs),
      scope: scope,
    );
  }

  /// refresh_token 是一次性的：先落新的 refresh，再落 access，崩溃最多要求重新授权。
  static Future<void> saveTokens(DiaryKind kind, FeishuTokenSet tokens) async {
    if (tokens.hasRefreshToken) {
      await _secure.write(
        key: _secureKey(kind, 'refresh_token'),
        value: tokens.refreshToken,
      );
      await _secure.write(
        key: _secureKey(kind, 'refresh_expires_at'),
        value: '${tokens.refreshExpiresAt?.millisecondsSinceEpoch ?? ''}',
      );
    }
    await _secure.write(
      key: _secureKey(kind, 'access_token'),
      value: tokens.accessToken,
    );
    await _secure.write(
      key: _secureKey(kind, 'access_expires_at'),
      value: '${tokens.accessExpiresAt.millisecondsSinceEpoch}',
    );
    await _secure.write(
      key: _secureKey(kind, 'scope'),
      value: tokens.scope ?? '',
    );
  }

  static Future<void> clearTokens(DiaryKind kind) async {
    for (final suffix in [
      'access_token',
      'access_expires_at',
      'refresh_token',
      'refresh_expires_at',
      'scope',
      'oauth_pending',
    ]) {
      await _secure.delete(key: _secureKey(kind, suffix));
    }
  }

  // --- 未完成的授权 ---

  static Future<void> savePendingAuth(
    DiaryKind kind,
    FeishuPendingAuth pending,
  ) async {
    await _secure.write(
      key: _secureKey(kind, 'oauth_pending'),
      value: jsonEncode(pending.toJson()),
    );
  }

  static Future<FeishuPendingAuth?> loadPendingAuth(DiaryKind kind) async {
    final raw = await _secure.read(key: _secureKey(kind, 'oauth_pending'));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return FeishuPendingAuth.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPendingAuth(DiaryKind kind) async {
    await _secure.delete(key: _secureKey(kind, 'oauth_pending'));
  }

  // --- 同步状态 ---

  static Future<bool> loadAutoSync(DiaryKind kind) async {
    final prefs = await _prefs;
    return prefs.getBool(_prefKey(kind, 'auto_sync')) ?? false;
  }

  static Future<void> saveAutoSync(DiaryKind kind, bool enabled) async {
    final prefs = await _prefs;
    await prefs.setBool(_prefKey(kind, 'auto_sync'), enabled);
  }

  static Future<bool> loadNeedsReauth(DiaryKind kind) async {
    final prefs = await _prefs;
    return prefs.getBool(_prefKey(kind, 'needs_reauth')) ?? false;
  }

  static Future<void> saveNeedsReauth(DiaryKind kind, bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(_prefKey(kind, 'needs_reauth'), value);
  }

  static Future<String?> loadPrimaryCalendarId(DiaryKind kind) async {
    final prefs = await _prefs;
    final value = prefs.getString(_prefKey(kind, 'primary_calendar_id'));
    return (value ?? '').isEmpty ? null : value;
  }

  static Future<void> savePrimaryCalendarId(DiaryKind kind, String id) async {
    final prefs = await _prefs;
    await prefs.setString(_prefKey(kind, 'primary_calendar_id'), id);
  }

  static Future<List<String>> loadPendingDates(DiaryKind kind) async {
    final prefs = await _prefs;
    return prefs.getStringList(_prefKey(kind, 'pending_dates')) ?? const [];
  }

  static Future<void> savePendingDates(
    DiaryKind kind,
    Iterable<String> dates,
  ) async {
    final prefs = await _prefs;
    final sorted = dates.toSet().toList()..sort();
    await prefs.setStringList(_prefKey(kind, 'pending_dates'), sorted);
  }

  static Future<List<String>> loadSyncedDates(DiaryKind kind) async {
    final prefs = await _prefs;
    return prefs.getStringList(_prefKey(kind, 'synced_dates')) ?? const [];
  }

  static Future<void> saveSyncedDates(
    DiaryKind kind,
    Iterable<String> dates,
  ) async {
    final prefs = await _prefs;
    final sorted = dates.toSet().toList()..sort();
    await prefs.setStringList(_prefKey(kind, 'synced_dates'), sorted);
  }

  static Future<DateTime?> loadLastSyncAt(DiaryKind kind) async {
    final prefs = await _prefs;
    final ms = prefs.getInt(_prefKey(kind, 'last_sync_at'));
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> saveLastSync(
    DiaryKind kind, {
    required DateTime at,
    required String summary,
  }) async {
    final prefs = await _prefs;
    await prefs.setInt(
        _prefKey(kind, 'last_sync_at'), at.millisecondsSinceEpoch);
    await prefs.setString(_prefKey(kind, 'last_sync_summary'), summary);
  }

  static Future<String?> loadLastSyncSummary(DiaryKind kind) async {
    final prefs = await _prefs;
    final value = prefs.getString(_prefKey(kind, 'last_sync_summary'));
    return (value ?? '').isEmpty ? null : value;
  }
}
