import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/diary_kind.dart';
import '../models/feishu_calendar_models.dart';
import 'feishu_calendar_log.dart';

/// 飞书凭据与同步状态的本地存储。
///
/// 密钥类优先走系统钥匙串；macOS 上应用是本地签名、没有钥匙串 entitlement
/// （PlatformException -34018），这时自动降级到 SharedPreferences，功能不受影响。
/// 所有键都按身份（g/j）显式拼，避免同步途中切换身份把结果写到另一个人名下。
class FeishuCredentialStore {
  FeishuCredentialStore._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static const String _secureDisabledKey = 'feishu_secure_disabled';

  static bool? _secureDisabled;

  static String _secureKey(DiaryKind kind, String suffix) =>
      'feishu_${suffix}_${kind.code}';

  static String _prefKey(DiaryKind kind, String suffix) =>
      'identity_${kind.code}_feishu_$suffix';

  static String _fallbackKey(String secureKey) => 'feishu_plain_$secureKey';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static Future<bool> _useSecure() async {
    final cached = _secureDisabled;
    if (cached != null) return !cached;
    final prefs = await _prefs;
    _secureDisabled = prefs.getBool(_secureDisabledKey) ?? false;
    return !_secureDisabled!;
  }

  static Future<void> _disableSecure(Object error) async {
    if (_secureDisabled == true) return;
    _secureDisabled = true;
    feishuLogWarning(
      '系统钥匙串不可用，飞书凭据改存应用数据（不影响使用）',
      error: error,
    );
    try {
      final prefs = await _prefs;
      await prefs.setBool(_secureDisabledKey, true);
    } catch (_) {
      // 偏好设置也不可用时就不记了。
    }
  }

  static Future<String?> _readSecure(String key) async {
    if (await _useSecure()) {
      try {
        return await _secure.read(key: key);
      } catch (e) {
        await _disableSecure(e);
      }
    }
    final prefs = await _prefs;
    return prefs.getString(_fallbackKey(key));
  }

  static Future<void> _writeSecure(String key, String value) async {
    if (await _useSecure()) {
      try {
        await _secure.write(key: key, value: value);
        return;
      } catch (e) {
        await _disableSecure(e);
      }
    }
    final prefs = await _prefs;
    await prefs.setString(_fallbackKey(key), value);
  }

  static Future<void> _deleteSecure(String key) async {
    if (await _useSecure()) {
      try {
        await _secure.delete(key: key);
      } catch (e) {
        await _disableSecure(e);
      }
    }
    try {
      final prefs = await _prefs;
      await prefs.remove(_fallbackKey(key));
    } catch (_) {
      // 忽略。
    }
  }

  @visibleForTesting
  static void resetSecureFallbackForTesting() => _secureDisabled = null;

  // --- 应用凭据 ---

  static Future<FeishuCredentials?> loadCredentials(DiaryKind kind) async {
    final appId = await _readSecure(_secureKey(kind, 'app_id'));
    final appSecret = await _readSecure(_secureKey(kind, 'app_secret'));
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
    await _writeSecure(_secureKey(kind, 'app_id'), credentials.appId.trim());
    await _writeSecure(
      _secureKey(kind, 'app_secret'),
      credentials.appSecret.trim(),
    );
    if (previous != null && previous.appId != credentials.appId.trim()) {
      await clearTokens(kind);
    }
  }

  static Future<void> clearCredentials(DiaryKind kind) async {
    await _deleteSecure(_secureKey(kind, 'app_id'));
    await _deleteSecure(_secureKey(kind, 'app_secret'));
    await clearTokens(kind);
  }

  // --- 令牌 ---

  static Future<FeishuTokenSet?> loadTokens(DiaryKind kind) async {
    final accessToken = await _readSecure(_secureKey(kind, 'access_token'));
    final accessExpiresAt =
        await _readSecure(_secureKey(kind, 'access_expires_at'));
    if ((accessToken ?? '').isEmpty || accessExpiresAt == null) return null;
    final accessMs = int.tryParse(accessExpiresAt);
    if (accessMs == null) return null;
    final refreshToken = await _readSecure(_secureKey(kind, 'refresh_token'));
    final refreshExpiresAt =
        await _readSecure(_secureKey(kind, 'refresh_expires_at'));
    final scope = await _readSecure(_secureKey(kind, 'scope'));
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
      await _writeSecure(
        _secureKey(kind, 'refresh_token'),
        tokens.refreshToken!,
      );
      await _writeSecure(
        _secureKey(kind, 'refresh_expires_at'),
        '${tokens.refreshExpiresAt?.millisecondsSinceEpoch ?? ''}',
      );
    }
    await _writeSecure(_secureKey(kind, 'access_token'), tokens.accessToken);
    await _writeSecure(
      _secureKey(kind, 'access_expires_at'),
      '${tokens.accessExpiresAt.millisecondsSinceEpoch}',
    );
    await _writeSecure(_secureKey(kind, 'scope'), tokens.scope ?? '');
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
      await _deleteSecure(_secureKey(kind, suffix));
    }
  }

  // --- 未完成的授权 ---

  static Future<void> savePendingAuth(
    DiaryKind kind,
    FeishuPendingAuth pending,
  ) async {
    await _writeSecure(
      _secureKey(kind, 'oauth_pending'),
      jsonEncode(pending.toJson()),
    );
  }

  static Future<FeishuPendingAuth?> loadPendingAuth(DiaryKind kind) async {
    final raw = await _readSecure(_secureKey(kind, 'oauth_pending'));
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
    await _deleteSecure(_secureKey(kind, 'oauth_pending'));
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
      _prefKey(kind, 'last_sync_at'),
      at.millisecondsSinceEpoch,
    );
    await prefs.setString(_prefKey(kind, 'last_sync_summary'), summary);
  }

  static Future<String?> loadLastSyncSummary(DiaryKind kind) async {
    final prefs = await _prefs;
    final value = prefs.getString(_prefKey(kind, 'last_sync_summary'));
    return (value ?? '').isEmpty ? null : value;
  }
}
