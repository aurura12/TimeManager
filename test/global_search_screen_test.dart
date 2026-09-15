import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:time_manager/models/global_search_result.dart';
import 'package:time_manager/screens/global_search_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/unified_search_service.dart';
import 'package:time_manager/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'identity_unbound_global_search_recent_v1': <String>['上一次搜索'],
    });
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  GlobalSearchIndex index() {
    return GlobalSearchIndex([
      GlobalSearchResult(
        type: GlobalSearchContentType.travel,
        date: DateTime(2026, 9, 14),
        title: '杭州西湖',
        summary: '地点：杭州西湖 · 事件：散步',
        details: '杭州西湖\n散步',
      ),
      GlobalSearchResult(
        type: GlobalSearchContentType.target,
        date: DateTime(2026, 9, 13),
        title: '阅读计划',
        summary: '时长目标 1 小时',
      ),
    ]);
  }

  Future<void> pumpSearch(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: GlobalSearchScreen(
          searchService: UnifiedSearchService.fromIndex(index()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('显示最近搜索，输入后显示模块、日期和摘要', (tester) async {
    await pumpSearch(tester);

    expect(find.text('最近搜索'), findsOneWidget);
    expect(find.text('上一次搜索'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '西湖');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('出行'), findsWidgets);
    expect(find.text('杭州西湖'), findsOneWidget);
    expect(find.textContaining('2026年9月14日'), findsOneWidget);
    expect(find.textContaining('事件：散步'), findsOneWidget);
  });

  testWidgets('没有匹配项时显示清晰空状态', (tester) async {
    await pumpSearch(tester);

    await tester.enterText(find.byType(TextField), '不存在的内容');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('未找到「不存在的内容」相关本地内容'), findsOneWidget);
    expect(find.text('可尝试切换内容、身份或日期筛选'), findsOneWidget);
  });
}
