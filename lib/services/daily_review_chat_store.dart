import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/daily_review_chat_message.dart';
import '../models/daily_review_chat_session.dart';
import 'app_identity_service.dart';
import 'daily_review_summary.dart';

class DailyReviewChatStore {
  static const _prefix = 'daily_review_chat_';

  /// 现有对话服务最多使用 20 轮，存储保留对应的 40 条消息。
  static const maxMessagesPerDay = 40;
  static const maxTotalBytes = 512 * 1024;
  static const retention = Duration(days: 30);
  static const maxMessageContentLength = 16384;
  static const maxSearchSessions = 60;

  /// A bounded local-only view used by the unified search index.
  ///
  /// The session is already normalized by this store, so callers do not get
  /// arbitrary preference data or an unbounded chat transcript.
  static const maxSearchMessageContentLength = maxMessageContentLength;

  static String _key(DateTime date) =>
      AppIdentityService.dataKeyForCurrentIdentity(
        '$_prefix${DailyReviewSummaryBuilder.dateKey(date)}',
      );

  static Future<DailyReviewChatSession> loadSession(DateTime date) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    await _cleanupPrefs(prefs, now: DateTime.now());
    final raw = prefs.getString(_key(date));
    if (raw == null || raw.isEmpty) {
      return const DailyReviewChatSession();
    }

    final parsed = _parseStoredSession(raw);
    if (parsed == null) return const DailyReviewChatSession();
    if (parsed.needsRewrite) {
      await prefs.setString(
        _key(date),
        _encodeSession(parsed.session.messages,
            dataHash: parsed.session.dataHash),
      );
    }
    return parsed.session;
  }

  /// Enumerates only current-identity, date-keyed sessions retained by this
  /// store. It performs no network request and does not inspect filesystem
  /// paths. Invalid dates, malformed JSON, and malformed individual messages
  /// are skipped so one damaged cache cannot stop search for other dates.
  static Future<List<DailyReviewChatSearchEntry>> loadSessionsForSearch({
    int limit = maxSearchSessions,
    DateTime? now,
  }) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    final effectiveNow = now ?? DateTime.now();
    await _cleanupPrefs(prefs, now: effectiveNow);
    final safeLimit = limit.clamp(1, maxSearchSessions);
    final prefix = AppIdentityService.dataKeyForCurrentIdentity(_prefix);
    final dates = <DateTime>[];

    // Restrict enumeration to the known current-identity chat prefix and the
    // canonical YYYY-MM-DD suffix used by save().
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(prefix)) continue;
      final date = _dateFromKey(key, prefix);
      if (date != null) dates.add(date);
    }
    dates.sort((a, b) => b.compareTo(a));

    final entries = <DailyReviewChatSearchEntry>[];
    for (final date in dates) {
      try {
        final parsed = _parseStoredSession(prefs.getString(_key(date)));
        final session = parsed?.session;
        if (session == null || session.messages.isEmpty) continue;
        entries.add(DailyReviewChatSearchEntry(date: date, session: session));
        if (entries.length >= safeLimit) break;
      } catch (_) {
        // A single corrupt session is isolated from the rest of the index.
      }
    }
    return List.unmodifiable(entries);
  }

  static _ParsedSession? _parseStoredSession(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final decoded = json.decode(raw);
      List<dynamic>? rawMessages;
      String? dataHash;
      if (decoded is List) {
        rawMessages = decoded;
      } else if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        final list = map['messages'];
        rawMessages = list is List ? list : const [];
        dataHash = map['dataHash'] is String ? map['dataHash'] as String : null;
      } else {
        return null;
      }

      final messages = <DailyReviewChatMessage>[];
      for (final value in rawMessages) {
        if (value is! Map) continue;
        try {
          messages.add(
            DailyReviewChatMessage.fromJson(
              Map<String, dynamic>.from(value),
            ),
          );
        } catch (_) {
          // Ignore one malformed message while retaining valid siblings.
        }
      }
      final normalized = _normalizeMessages(messages);
      return _ParsedSession(
        session: DailyReviewChatSession(
          messages: normalized,
          dataHash: dataHash,
        ),
        needsRewrite: !_sameMessages(messages, normalized),
      );
    } catch (_) {
      return null;
    }
  }

  static DateTime? _dateFromKey(String key, String prefix) {
    final value = key.substring(prefix.length);
    final date = DateTime.tryParse(value);
    if (date == null || DailyReviewSummaryBuilder.dateKey(date) != value) {
      return null;
    }
    return DateTime(date.year, date.month, date.day);
  }

  static List<DailyReviewChatMessage> _normalizeMessages(
    List<DailyReviewChatMessage> messages,
  ) {
    final start = messages.length > maxMessagesPerDay
        ? messages.length - maxMessagesPerDay
        : 0;
    return messages
        .sublist(start)
        .map(
          (message) => message.content.length <= maxMessageContentLength
              ? message
              : message.copyWith(
                  content:
                      message.content.substring(0, maxMessageContentLength),
                ),
        )
        .toList(growable: false);
  }

  static String _encodeSession(
    List<DailyReviewChatMessage> messages, {
    String? dataHash,
  }) {
    return json.encode({
      'v': 1,
      if (dataHash != null) 'dataHash': dataHash,
      'messages': messages.map((m) => m.toJson()).toList(),
    });
  }

  static bool _sameMessages(
    List<DailyReviewChatMessage> a,
    List<DailyReviewChatMessage> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.role != right.role ||
          left.content != right.content ||
          left.createdAt != right.createdAt ||
          left.fromReview != right.fromReview ||
          left.contextSync != right.contextSync) {
        return false;
      }
    }
    return true;
  }

  static Future<void> _cleanupPrefs(
    SharedPreferences prefs, {
    required DateTime now,
  }) async {
    final prefix = AppIdentityService.dataKeyForCurrentIdentity(_prefix);
    final cutoff = DateTime(now.year, now.month, now.day).subtract(retention);
    final entries = <_StoredChat>[];

    for (final key in prefs.getKeys()) {
      if (!key.startsWith(prefix)) continue;
      String? raw;
      try {
        raw = prefs.getString(key);
      } catch (_) {
        await prefs.remove(key);
        continue;
      }
      final date = _dateFromKey(key, prefix);
      if (raw == null || date == null || date.isBefore(cutoff)) {
        await prefs.remove(key);
        continue;
      }
      entries.add(_StoredChat(key: key, date: date, raw: raw));
    }

    entries.sort((a, b) => a.date.compareTo(b.date));
    var totalBytes = entries.fold<int>(
      0,
      (sum, entry) => sum + _entryByteLength(entry),
    );
    for (final entry in entries) {
      if (totalBytes <= maxTotalBytes) break;
      await prefs.remove(entry.key);
      totalBytes -= _entryByteLength(entry);
    }
  }

  static int _entryByteLength(_StoredChat entry) {
    return utf8.encode(entry.key).length + utf8.encode(entry.raw).length;
  }

  static Future<List<DailyReviewChatMessage>> load(DateTime date) async {
    final session = await loadSession(date);
    return session.messages;
  }

  static Future<void> save(
    DateTime date,
    List<DailyReviewChatMessage> messages, {
    String? dataHash,
    DateTime? now,
  }) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    final normalizedMessages = _normalizeMessages(messages);
    final encoded = _encodeSession(normalizedMessages, dataHash: dataHash);
    await prefs.setString(_key(date), encoded);
    await _cleanupPrefs(prefs, now: now ?? DateTime.now());
  }

  static Future<void> clear(DateTime date) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(date));
  }

  /// Removes conversations older than [retention] and trims the current
  /// identity's complete chat database to [maxTotalBytes].
  static Future<void> cleanup({DateTime? now}) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    await _cleanupPrefs(prefs, now: now ?? DateTime.now());
  }
}

class DailyReviewChatSearchEntry {
  final DateTime date;
  final DailyReviewChatSession session;

  const DailyReviewChatSearchEntry({
    required this.date,
    required this.session,
  });
}

class _ParsedSession {
  final DailyReviewChatSession session;
  final bool needsRewrite;

  const _ParsedSession({
    required this.session,
    required this.needsRewrite,
  });
}

class _StoredChat {
  final String key;
  final DateTime date;
  final String raw;

  const _StoredChat({
    required this.key,
    required this.date,
    required this.raw,
  });
}
