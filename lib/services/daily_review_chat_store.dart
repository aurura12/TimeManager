import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/daily_review_chat_message.dart';
import 'daily_review_summary.dart';

class DailyReviewChatStore {
  static const _prefix = 'daily_review_chat_';

  static String _key(DateTime date) => '$_prefix${DailyReviewSummaryBuilder.dateKey(date)}';

  static Future<List<DailyReviewChatMessage>> load(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(date));
    if (raw == null || raw.isEmpty) return [];

    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return [];
      return decoded
          .map((e) => DailyReviewChatMessage.fromJson(
                Map<String, dynamic>.from(e as Map),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(
    DateTime date,
    List<DailyReviewChatMessage> messages,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = json.encode(messages.map((m) => m.toJson()).toList());
    await prefs.setString(_key(date), encoded);
  }

  static Future<void> clear(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(date));
  }
}
