import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:time_manager/models/global_search_result.dart';
import 'package:time_manager/screens/daily_review_screen.dart';
import 'package:time_manager/screens/global_search_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/daily_review_summary.dart';
import 'package:time_manager/services/unified_search_service.dart';
import 'package:time_manager/theme/app_theme.dart';

void _installPluginMocks({bool aiEnabled = false}) {
  SharedPreferences.setMockInitialValues({
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'j',
    // 关掉 AI：复盘页只渲染本地条目，不发起任何请求
    'identity_j_daily_review_ai_enabled': aiEnabled,
    'identity_j_daily_review_ai_consent': true,
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
}

Future<void> _pumpReview(WidgetTester tester, DateTime Function() clock) async {
  // 日期条是按需构建的 ListView：视口拉高，避免选中项滚动后把顶部日期移出构建范围
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final today = DateTime(clock().year, clock().month, clock().day);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: DailyReviewScreen(date: today, clock: clock),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Text _dateText(WidgetTester tester, DateTime date) => tester.widget<Text>(
      find.text('${date.month}/${date.day}', skipOffstage: false),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  testWidgets('复盘页跨午夜：新的一天补到顶部并跟着翻页', (tester) async {
    _installPluginMocks();
    // 从当天 23:59:59 起步，跨日定时器只等 1 秒
    var clock = DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);
    final tomorrow = today.add(const Duration(days: 1));
    clock = DateTime(today.year, today.month, today.day, 23, 59, 59);
    await _pumpReview(tester, () => clock);

    expect(find.text('今天'), findsOneWidget);
    expect(_dateText(tester, today).style?.fontWeight, FontWeight.w700);

    clock = tomorrow.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('今天'), findsOneWidget);
    expect(_dateText(tester, tomorrow).style?.fontWeight, FontWeight.w700);
  });

  testWidgets('复盘页停在更早日期时跨日不抢视图，新的一天仍出现', (tester) async {
    _installPluginMocks();
    var clock = DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final tomorrow = today.add(const Duration(days: 1));
    clock = DateTime(today.year, today.month, today.day, 23, 59, 59);
    await _pumpReview(tester, () => clock);

    await tester.tap(find.text('${yesterday.month}/${yesterday.day}'));
    await tester.pumpAndSettle();
    expect(_dateText(tester, yesterday).style?.fontWeight, FontWeight.w700);

    clock = tomorrow.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));

    // 新的一天出现在顶部，但选中仍停在用户正在看的日期
    expect(_dateText(tester, tomorrow).style?.fontWeight, FontWeight.w500);
    expect(_dateText(tester, yesterday).style?.fontWeight, FontWeight.w700);
  });

  testWidgets('复盘页隐藏时跨日，重新可见后安全更新日期', (tester) async {
    _installPluginMocks();
    var clock = DateTime(2026, 10, 6, 23, 59, 59);
    Widget page(bool active) => MaterialApp(
          theme: AppTheme.light(),
          home: TickerMode(
            enabled: active,
            child: DailyReviewScreen(
              date: DateTime(2026, 10, 6),
              clock: () => clock,
            ),
          ),
        );

    await tester.pumpWidget(page(true));
    await tester.pump();
    await tester.pumpWidget(page(false));
    clock = DateTime(2026, 10, 7, 8);
    await tester.pumpWidget(page(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(_dateText(tester, DateTime(2026, 10, 7)).style?.fontWeight,
        FontWeight.w700);
  });

  testWidgets('跨日后 AI 请求未完成时，滚动仍能更新选中日期', (tester) async {
    _installPluginMocks(aiEnabled: true);
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var clock = DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    clock = DateTime(today.year, today.month, today.day, 23, 59, 59);
    final pending = Completer<DailyReviewAiResult>();
    var tomorrowRequested = false;

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: DailyReviewScreen(
        date: today,
        clock: () => clock,
        reviewLoader: (date) {
          if (date == tomorrow) {
            tomorrowRequested = true;
            return pending.future;
          }
          return Future.value(DailyReviewAiResult(
            date: date,
            title: '复盘',
            body: '已有复盘',
          ));
        },
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    clock = tomorrow.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 30 && !tomorrowRequested; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tomorrowRequested, isTrue);
    expect(pending.isCompleted, isFalse);

    await tester.drag(find.byType(ListView).last, const Offset(0, -560));
    await tester.pumpAndSettle();
    expect(_dateText(tester, tomorrow).style?.fontWeight, FontWeight.w500);

    pending.complete(DailyReviewAiResult(
      date: tomorrow,
      title: '复盘',
      body: '新的复盘',
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('全局搜索的相对区间跨午夜后按新的一天重算', (tester) async {
    _installPluginMocks();
    var clock = DateTime(2026, 9, 15, 23, 59, 59);
    final index = GlobalSearchIndex([
      GlobalSearchResult(
        type: GlobalSearchContentType.travel,
        date: DateTime(2026, 9, 14),
        title: '杭州西湖',
        summary: '地点：杭州西湖 · 事件：散步',
        details: '杭州西湖\n散步',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: GlobalSearchScreen(
          searchService: UnifiedSearchService.fromIndex(index),
          clock: () => clock,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('近 7 天'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '西湖');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('杭州西湖'), findsOneWidget);

    clock = DateTime(2026, 9, 22, 0, 0, 5);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // 「近 7 天」平移到新的一天后，旧结果不再命中
    expect(find.text('杭州西湖'), findsNothing);
  });
}
