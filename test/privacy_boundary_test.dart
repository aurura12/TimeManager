import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/app_log_entry.dart';
import 'package:time_manager/models/daily_review_chat_message.dart';
import 'package:time_manager/screens/daily_review_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/app_log_store.dart';
import 'package:time_manager/services/daily_review_chat_store.dart';
import 'package:time_manager/services/daily_review_summary.dart';
import 'package:time_manager/services/siliconflow_ai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('FileAppLogStore applies the 30-day TTL and approximately 2MB cap',
      () async {
    final directory = await Directory.systemTemp.createTemp('time_manager_logs');
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime.utc(2026, 9, 15);
    final store = FileAppLogStore(
      applicationSupportDirectory: () async => directory,
      clock: () => now,
    );

    final oldLine = _logLine(
      now.subtract(const Duration(days: 31)),
      '过期日志',
    );
    final recentLine = _logLine(now, '保留日志');
    await store.rewriteLines([oldLine, recentLine]);

    expect(await store.readLines(), [recentLine]);

    final largeLines = List<String>.generate(
      300,
      (index) => _logLine(now.add(Duration(seconds: index)), 'x' * 10000),
    );
    await store.rewriteLines(largeLines);
    final retained = await store.readLines();
    final bytes = retained.fold<int>(
      0,
      (sum, line) => sum + utf8.encode('$line\n').length,
    );

    expect(bytes, lessThanOrEqualTo(FileAppLogStore.maxBytes));
    expect(retained.last, largeLines.last);
    expect(retained.length, lessThan(largeLines.length));
  });

  test('DailyReviewChatStore limits messages per day and persists the trim',
      () async {
    final date = DateTime(2026, 9, 15);
    final now = DateTime(2026, 9, 15, 12);
    final messages = List<DailyReviewChatMessage>.generate(
      DailyReviewChatStore.maxMessagesPerDay + 5,
      (index) => DailyReviewChatMessage(
        role: index.isEven ? 'user' : 'assistant',
        content: '消息 $index',
        createdAt: index,
      ),
    );

    await DailyReviewChatStore.save(date, messages, now: now);

    final loaded = await DailyReviewChatStore.loadSession(date);
    expect(loaded.messages, hasLength(DailyReviewChatStore.maxMessagesPerDay));
    expect(loaded.messages.first.content, '消息 5');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(
      'identity_j_daily_review_chat_${DailyReviewSummaryBuilder.dateKey(date)}',
    );
    expect(raw, isNotNull);
    final stored = jsonDecode(raw!) as Map<String, dynamic>;
    expect((stored['messages'] as List), hasLength(40));
  });

  test('DailyReviewChatStore removes expired days and enforces total bytes',
      () async {
    final now = DateTime(2026, 9, 15, 12);
    final expiredDate = DateTime(2026, 8, 10);
    await DailyReviewChatStore.save(
      expiredDate,
      [_message('过期对话')],
      now: now,
    );

    for (var index = 0; index < 20; index++) {
      await DailyReviewChatStore.save(
        now.subtract(Duration(days: index)),
        [_message('$index ${'中' * 12000}')],
        now: now,
      );
    }
    await DailyReviewChatStore.cleanup(now: now);

    final prefs = await SharedPreferences.getInstance();
    final prefix = 'identity_j_daily_review_chat_';
    final keys = prefs.getKeys().where((key) => key.startsWith(prefix));
    final bytes = keys.fold<int>(
      0,
      (sum, key) =>
          sum + utf8.encode(key).length + utf8.encode(prefs.getString(key)!).length,
    );

    expect(prefs.getString('$prefix${DailyReviewSummaryBuilder.dateKey(expiredDate)}'),
        isNull);
    expect(bytes, lessThanOrEqualTo(DailyReviewChatStore.maxTotalBytes));
    expect(
      prefs.getString(
        '$prefix${DailyReviewSummaryBuilder.dateKey(now)}',
      ),
      isNotNull,
    );
  });

  test('disabled AI stops before creating an HTTP client', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('identity_j_daily_review_ai_enabled', false);
    await prefs.setBool('identity_j_daily_review_ai_consent', true);

    var attempted = false;
    final result = await HttpOverrides.runZoned(
      () => SiliconFlowAiService.generateDailyReview(userPrompt: '不应发送'),
      createHttpClient: (_) {
        attempted = true;
        throw StateError('HTTP should not be reached');
      },
    );

    expect(result.content, isNull);
    expect(result.timedOut, isFalse);
    expect(attempted, isFalse);
  });

  test('AI cache expires and clearAiCache removes current identity cache',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('identity_j_daily_review_ai_enabled', true);
    await prefs.setBool('identity_j_daily_review_ai_consent', true);
    final date = DateTime(2026, 8, 1);
    final hash = await DailyReviewSummaryBuilder.computeDayDataHash(date);
    final cacheKey =
        'identity_j_daily_review_ai_cache_${DailyReviewSummaryBuilder.dateKey(date)}';
    await prefs.setString(
      cacheKey,
      jsonEncode({
        'hash': hash,
        'body': '过期复盘',
        'createdAt': DateTime(2026, 8, 1).toUtc().toIso8601String(),
      }),
    );

    expect(await DailyReviewSummaryBuilder.loadCachedAi(date), isNull);
    expect(prefs.getString(cacheKey), isNull);

    await prefs.setString('identity_j_daily_review_ai_cache_2026-09-15', 'x');
    await DailyReviewSummaryBuilder.clearAiCache();
    expect(prefs.getString('identity_j_daily_review_ai_cache_2026-09-15'), isNull);
  });

  testWidgets('首次自动复盘请求前显示数据使用说明', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DailyReviewScreen(date: DateTime(2026, 9, 15)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('使用 AI 复盘前请确认'), findsOneWidget);
    expect(find.text('同意并开启'), findsOneWidget);

    await tester.tap(find.text('暂不使用'));
    await tester.pump();
  });

  testWidgets('复盘页的 AI 设置可以关闭并清理缓存', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('identity_j_daily_review_ai_enabled', false);
    await prefs.setBool('identity_j_daily_review_ai_consent', true);
    await prefs.setString('identity_j_daily_review_ai_cache_2026-09-15', 'cached');

    await tester.pumpWidget(
      MaterialApp(
        home: DailyReviewScreen(date: DateTime(2026, 9, 15)),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('AI 设置'));
    await tester.pumpAndSettle();

    expect(find.text('清理 AI 缓存'), findsOneWidget);
    await tester.tap(find.text('清理 AI 缓存'));
    await tester.pumpAndSettle();

    expect(prefs.getString('identity_j_daily_review_ai_cache_2026-09-15'), isNull);
  });
}

String _logLine(DateTime timestamp, String message) {
  return jsonEncode(
    AppLogEntry(
      timestamp: timestamp,
      level: AppLogLevel.info,
      source: 'test',
      message: message,
    ).toJson(),
  );
}

DailyReviewChatMessage _message(String content) {
  return DailyReviewChatMessage(
    role: 'user',
    content: content,
    createdAt: 1,
  );
}
