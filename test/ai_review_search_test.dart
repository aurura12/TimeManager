import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/daily_review_chat_message.dart';
import 'package:time_manager/models/global_search_result.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/daily_review_chat_store.dart';
import 'package:time_manager/services/daily_review_summary.dart';
import 'package:time_manager/services/unified_search_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('摘要枚举只返回当前身份、未过期且哈希匹配的缓存', () async {
    final now = DateTime(2026, 9, 15, 12);
    final validDate = DateTime(2026, 9, 14);
    final validHash =
        await DailyReviewSummaryBuilder.computeDayDataHash(validDate);
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      _summaryKey(validDate),
      jsonEncode({
        'hash': validHash,
        'body': '今天专注完成了重要工作。',
        'createdAt': DateTime(2026, 9, 14, 20).toUtc().toIso8601String(),
      }),
    );
    await prefs.setString(
      _summaryKey(DateTime(2026, 9, 13)),
      jsonEncode({'hash': 'stale', 'body': '不应出现'}),
    );
    await prefs.setString(
      _summaryKey(DateTime(2026, 8, 1)),
      jsonEncode({
        'hash': validHash,
        'body': '过期内容',
        'createdAt': DateTime(2026, 8, 1).toUtc().toIso8601String(),
      }),
    );
    await prefs.setString(_summaryKey(DateTime(2026, 9, 12)), '{坏缓存');
    await prefs.setString(
      'identity_g_daily_review_ai_cache_2026-09-14',
      jsonEncode({'hash': validHash, 'body': '另一身份内容'}),
    );

    final entries = await DailyReviewSummaryBuilder.loadCachedForSearch(
      limit: 999,
      now: now,
    );

    expect(entries, hasLength(1));
    expect(entries.single.date, validDate);
    expect(entries.single.body, '今天专注完成了重要工作。');
    expect(
      prefs.getString(_summaryKey(DateTime(2026, 8, 1))),
      isNull,
    );
  });

  test('对话枚举兼容旧格式并跳过损坏会话，同时保留消息上限', () async {
    final now = DateTime(2026, 9, 15, 12);
    final prefs = await SharedPreferences.getInstance();
    final legacyDate = DateTime(2026, 9, 13);
    await prefs.setString(
      _chatKey(legacyDate),
      jsonEncode([
        {
          'role': 'assistant',
          'content': '旧格式对话关键词',
          'createdAt': 1,
        },
        '损坏消息',
      ]),
    );
    await prefs.setString(
      _chatKey(DateTime(2026, 9, 12)),
      'not-json',
    );
    await DailyReviewChatStore.save(
      DateTime(2026, 9, 14),
      [
        DailyReviewChatMessage(
          role: 'user',
          content: 'x' * (DailyReviewChatStore.maxMessageContentLength + 100),
          createdAt: 2,
        ),
      ],
      now: now,
    );

    final sessions = await DailyReviewChatStore.loadSessionsForSearch(
      limit: 999,
      now: now,
    );

    expect(sessions, hasLength(2));
    expect(sessions.map((entry) => entry.date), [
      DateTime(2026, 9, 14),
      DateTime(2026, 9, 13),
    ]);
    expect(sessions.last.session.messages.single.content, '旧格式对话关键词');
    expect(
      sessions.first.session.messages.single.content.length,
      DailyReviewChatStore.maxMessageContentLength,
    );
  });

  test('统一搜索纳入摘要和对话，带 AI 复盘模块与日期且不触发网络', () async {
    final date = DateTime(2026, 9, 14);
    final prefs = await SharedPreferences.getInstance();
    final hash = await DailyReviewSummaryBuilder.computeDayDataHash(date);
    await prefs.setString(
      _summaryKey(date),
      jsonEncode({
        'hash': hash,
        'body': '今天专注完成了重要工作。',
        'createdAt': date.toUtc().toIso8601String(),
      }),
    );
    await DailyReviewChatStore.save(
      date,
      [
        DailyReviewChatMessage(
          role: 'user',
          content: '请解释专注时间',
          createdAt: 10,
        ),
        DailyReviewChatMessage(
          role: 'assistant',
          content: '专注时间主要用于完成重要工作。',
          createdAt: 11,
        ),
      ],
      now: DateTime(2026, 9, 15, 12),
    );

    final service = UnifiedSearchService(
      travelLoader: () async => null,
      checkInLoader: () async => null,
    );
    var attemptedNetwork = false;
    final results = await HttpOverrides.runZoned(
      () => service.search(
        '专注',
        contentType: GlobalSearchContentType.aiReview,
      ),
      createHttpClient: (_) {
        attemptedNetwork = true;
        throw StateError('AI search must remain local');
      },
    );

    expect(attemptedNetwork, isFalse);
    expect(results, hasLength(3));
    expect(
        results
            .every((result) => result.type == GlobalSearchContentType.aiReview),
        isTrue);
    expect(results.every((result) => result.moduleLabel == 'AI复盘'), isTrue);
    expect(results.every((result) => result.date == date), isTrue);
    expect(results.any((result) => result.details!.contains('重要工作')), isTrue);
  });
}

String _summaryKey(DateTime date) {
  return 'identity_j_daily_review_ai_cache_${DailyReviewSummaryBuilder.dateKey(date)}';
}

String _chatKey(DateTime date) {
  return 'identity_j_daily_review_chat_${DailyReviewSummaryBuilder.dateKey(date)}';
}
