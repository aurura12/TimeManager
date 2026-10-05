import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/screens/diary_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/theme/app_theme.dart';

String _dateLabel(DateTime date) => DateFormat('yyyy年M月d日').format(date);

void _installPluginMocks() {
  SharedPreferences.setMockInitialValues({});
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_diary_date_navigation_test',
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 60,
}) async {
  for (var i = 0; i < maxPumps && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pumpDiary(WidgetTester tester) async {
  _installPluginMocks();
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light(), home: const DiaryScreen()),
  );
  // 等待 _loadInitial 完成异步读取（偏好 + 安全存储）。
  await _pumpUntil(tester, find.byIcon(Icons.chevron_left));
  expect(find.byIcon(Icons.chevron_left), findsOneWidget);
  expect(find.byIcon(Icons.chevron_right), findsOneWidget);
}

void main() {
  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  testWidgets('日期按钮两侧的前一天/后一天按钮可切换日记日期', (tester) async {
    final today = DateTime.now();
    final yesterday = today.subtract(const Duration(days: 1));
    await _pumpDiary(tester);

    expect(find.text(_dateLabel(today)), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await _pumpUntil(tester, find.text(_dateLabel(yesterday)));
    expect(find.text(_dateLabel(yesterday)), findsOneWidget);
    expect(find.text(_dateLabel(today)), findsNothing);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await _pumpUntil(tester, find.text(_dateLabel(today)));
    expect(find.text(_dateLabel(today)), findsOneWidget);
    expect(find.text(_dateLabel(yesterday)), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('跨天切换可连续前进并原路返回，日期标签与边界一致', (tester) async {
    final today = DateTime.now();
    await _pumpDiary(tester);

    for (var i = 1; i <= 2; i++) {
      await tester.tap(find.byIcon(Icons.chevron_right));
      await _pumpUntil(tester, find.text(_dateLabel(
        today.add(Duration(days: i)),
      )));
      expect(
        find.text(_dateLabel(today.add(Duration(days: i)))),
        findsOneWidget,
        reason: '连续点击应逐日前进',
      );
    }

    for (var i = 1; i >= 0; i--) {
      await tester.tap(find.byIcon(Icons.chevron_left));
      await _pumpUntil(tester, find.text(_dateLabel(
        today.add(Duration(days: i)),
      )));
      expect(
        find.text(_dateLabel(today.add(Duration(days: i)))),
        findsOneWidget,
        reason: '逐日返回应恢复对应日期',
      );
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('日期按钮仍可打开日历选择面板', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final today = DateTime.now();
    await _pumpDiary(tester);

    await tester.tap(
      find.widgetWithIcon(OutlinedButton, Icons.calendar_today_outlined),
    );

    final monthLabel = '${today.year}年${today.month}月';
    await _pumpUntil(tester, find.text(monthLabel));
    expect(find.text(monthLabel), findsOneWidget, reason: '应弹出当前月份的日历面板');
    expect(tester.takeException(), isNull);
  });
}
