import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一次日程状态检查后保存的远端版本基线。
///
/// 远端文件列表的 SHA 只用于判断某一天是否需要重新读取正文；正文是否
/// 等价仍由日程槽位比较逻辑决定。`pendingKinds` 保存已知但尚未解决的
/// 日期，避免用户每次打开同步中心都重复读取同一份未变化的远端文件。
class ScheduleSyncManifest {
  const ScheduleSyncManifest({
    required this.remoteDates,
    required this.remoteShaByDate,
    required this.localFingerprintByDate,
    required this.pendingKinds,
  });

  final Set<String> remoteDates;
  final Map<String, String> remoteShaByDate;
  final Map<String, String> localFingerprintByDate;
  final Map<String, String> pendingKinds;

  Map<String, dynamic> toJson() => {
        'remoteDates': remoteDates.toList()..sort(),
        'remoteShaByDate': remoteShaByDate,
        'localFingerprintByDate': localFingerprintByDate,
        'pendingKinds': pendingKinds,
      };

  factory ScheduleSyncManifest.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('日程同步基线格式无效');
    }
    final remoteDates = _stringSet(raw['remoteDates']);
    final remoteShaByDate = _stringMap(raw['remoteShaByDate']);
    final localFingerprintByDate = _stringMap(raw['localFingerprintByDate']);
    final pendingKinds = _stringMap(raw['pendingKinds']);
    return ScheduleSyncManifest(
      remoteDates: remoteDates,
      remoteShaByDate: remoteShaByDate,
      localFingerprintByDate: localFingerprintByDate,
      pendingKinds: pendingKinds,
    );
  }

  static Set<String> _stringSet(Object? raw) {
    if (raw is! List) return <String>{};
    return raw
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return <String, String>{};
    final result = <String, String>{};
    raw.forEach((key, value) {
      final normalizedKey = key.toString();
      final normalizedValue = value?.toString() ?? '';
      if (normalizedKey.isNotEmpty && normalizedValue.isNotEmpty) {
        result[normalizedKey] = normalizedValue;
      }
    });
    return result;
  }
}

/// 按日程身份保存状态检查基线，不包含 Token 等敏感信息。
class ScheduleSyncManifestStore {
  static const _keyPrefix = 'schedule_sync_manifest_v1_';

  static String _storageKey(String userCode) => '$_keyPrefix$userCode';

  static Future<ScheduleSyncManifest?> load(String userCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey(userCode));
      if (raw == null || raw.trim().isEmpty) return null;
      return ScheduleSyncManifest.fromJson(jsonDecode(raw));
    } catch (_) {
      // 基线损坏或 SharedPreferences 暂时不可用时退回一次完整检查，
      // 不能因为缓存异常阻断同步中心。
      return null;
    }
  }

  static Future<bool> save(
    String userCode,
    ScheduleSyncManifest manifest,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(
        _storageKey(userCode),
        jsonEncode(manifest.toJson()),
      );
    } catch (_) {
      return false;
    }
  }

  static Future<bool> remove(String userCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.remove(_storageKey(userCode));
    } catch (_) {
      return false;
    }
  }
}
