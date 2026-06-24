import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/daily_review_chat_message.dart';
import '../models/daily_review_chat_session.dart';
import 'daily_review_summary.dart';

class DailyReviewChatStore {
  static const _prefix = 'daily_review_chat_';

  static String _key(DateTime date) =>
      '$_prefix${DailyReviewSummaryBuilder.dateKey(date)}';

  static Future<DailyReviewChatSession> loadSession(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(date));
    if (raw == null || raw.isEmpty) {
      return const DailyReviewChatSession();
    }

    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        final messages = decoded
            .map((e) => DailyReviewChatMessage.fromJson(
                  Map<String, dynamic>.from(e as Map),
                ))
            .toList();
        return DailyReviewChatSession(messages: messages);
      }
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        final list = map['messages'];
        final messages = list is List
            ? list
                .map((e) => DailyReviewChatMessage.fromJson(
                      Map<String, dynamic>.from(e as Map),
                    ))
                .toList()
            : <DailyReviewChatMessage>[];
        return DailyReviewChatSession(
          messages: messages,
          dataHash: map['dataHash'] as String?,
        );
      }
    } catch (_) {}
    return const DailyReviewChatSession();
  }

  static Future<List<DailyReviewChatMessage>> load(DateTime date) async {
    final session = await loadSession(date);
    return session.messages;
  }

  static Future<void> save(
    DateTime date,
    List<DailyReviewChatMessage> messages, {
    String? dataHash,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = json.encode({
      'v': 1,
      if (dataHash != null) 'dataHash': dataHash,
      'messages': messages.map((m) => m.toJson()).toList(),
    });
    await prefs.setString(_key(date), encoded);
  }

  static Future<void> clear(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(date));
  }
}
