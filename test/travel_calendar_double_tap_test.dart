import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/models/travel_record.dart';
import 'package:time_manager/screens/travel_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/sync_status_coordinator.dart';
import 'package:time_manager/theme/app_theme.dart';

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

Future<void> _pumpTravel(
  WidgetTester tester,
  SyncStatusCoordinator coordinator,
) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<SyncStatusCoordinator>.value(
      value: coordinator,
      child: MaterialApp(theme: AppTheme.light(), home: const TravelScreen()),
    ),
  );
  await _pumpUntil(
    tester,
    () => find
        .byWidgetPredicate((widget) =>
            widget is Tooltip && (widget.message?.startsWith('新增记录') ?? false))
        .evaluate()
        .isNotEmpty,
  );
}

/// 切到日历视图（桌面宽窗口默认多月视图）。
Future<void> _openCalendar(WidgetTester tester) async {
  await tester.tap(find.text('日历'));
  await tester.pumpAndSettle();
}

Finder _dayCell(DateTime date) => find.byKey(
      ValueKey('travel-calendar-day-${DateFormat('yyyy-MM-dd').format(date)}'),
    );

/// 模拟双击：两次点击之间只隔一个很短的帧，落在双击判定窗口内。
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'read' ? 'fake-token' : null,
    );
  });
  tearDown(AppIdentityService.resetForTesting);

  testWidgets('双击有记录的日期打开编辑弹窗', (tester) async {
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(coordinator.dispose);
    final today = DateTime.now();
    final remote = TravelRecordsDocument(records: [
      TravelRecord(
        date: DateTime(today.year, today.month, today.day),
        location: '杭州',
        event: '散步',
      ),
    ]).toMarkdown();

    await http.runWithClient(() async {
      await _pumpTravel(tester, coordinator);
      await _pumpUntil(
          tester, () => find.text('杭州').evaluate().isNotEmpty);
      await _openCalendar(tester);

      await _doubleTap(tester, _dayCell(today));
      expect(find.text('编辑出行记录'), findsOneWidget);
      expect(find.text('散步'), findsWidgets, reason: '编辑弹窗要带出当天已有内容');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('编辑出行记录'), findsNothing);
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              if (request.method != 'GET') {
                return http.Response('', 500);
              }
              return http.Response(
                jsonEncode({
                  'sha': 'remote-sha',
                  'content': base64Encode(utf8.encode(remote)),
                }),
                200,
              );
            }));
  });

  testWidgets('双击没有记录的日期按该日期新增，隔太久的两次单击不算双击', (tester) async {
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(coordinator.dispose);
    final today = DateTime.now();
    final target =
        DateTime(today.year, today.month, today.day == 1 ? 2 : 1);

    await http.runWithClient(() async {
      await _pumpTravel(tester, coordinator);
      await _pumpUntil(
          tester,
          () =>
              coordinator.stateFor(SyncModule.travel).status !=
              SyncModuleStatus.idle);
      await _openCalendar(tester);

      // 第一次单击只选中日期；等过了双击窗口再点一次，仍然只选中，不弹窗。
      await tester.tap(_dayCell(target));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(_dayCell(target));
      await tester.pumpAndSettle();
      expect(find.text('新增出行记录'), findsNothing);

      // 等待窗口彻底过期后重新双击，才按该日期打开新增弹窗。
      await tester.pump(const Duration(milliseconds: 500));
      await _doubleTap(tester, _dayCell(target));
      expect(find.text('新增出行记录'), findsOneWidget);
      expect(find.text(DateFormat('yyyy-MM-dd').format(target)), findsOneWidget,
          reason: '新增弹窗的日期要是双击的那一天');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('新增出行记录'), findsNothing);
      expect(tester.takeException(), isNull);
    },
        () => MockClient((_) async => http.Response('', 404)));
  });
}
