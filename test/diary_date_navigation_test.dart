import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/screens/diary_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/diary_local_store.dart';
import 'package:time_manager/theme/app_theme.dart';

String _dateLabel(DateTime date) => DateFormat('yyyy年M月d日').format(date);

class _FailDiaryBodyStore extends InMemorySharedPreferencesStore {
  _FailDiaryBodyStore(super.data) : super.withData();

  bool failBody = false;
  bool throwOnBody = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failBody && key.startsWith('flutter.diary_draft_g_')) {
      if (throwOnBody) throw PlatformException(code: 'disk-full');
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

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
      await _pumpUntil(
          tester,
          find.text(_dateLabel(
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
      await _pumpUntil(
          tester,
          find.text(_dateLabel(
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

  testWidgets('切后台立即落盘，不必等 350ms 防抖', (tester) async {
    await _pumpDiary(tester);
    final today = DateTime.now();
    const text = '切后台前输入的内容';

    await tester.enterText(find.byType(TextField), text);
    // 不推进 350ms 防抖，直接进入后台
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    String? saved;
    await tester.runAsync(() async {
      saved = await DiaryLocalStore.loadDraftBody(DiaryKind.g, today);
    });
    expect(saved, text);

    // 按合法的生命周期顺序回到前台（paused → hidden → inactive → resumed）
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  for (final throws in [false, true]) {
    testWidgets('当前草稿保存${throws ? '抛异常' : '返回 false'}时不能从文件树覆盖编辑器',
        (tester) async {
      await http.runWithClient(() async {
        _installPluginMocks();
        final values = <String, Object>{
          AppIdentityService.modeKey: 'manual',
          AppIdentityService.legacyScheduleUserKey: DiaryKind.g.code,
        };
        SharedPreferences.setMockInitialValues(values);
        final store = _FailDiaryBodyStore({
          for (final entry in values.entries)
            'flutter.${entry.key}': entry.value,
        });
        SharedPreferencesStorePlatform.instance = store;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'read' ? 'fake-token' : null,
        );

        await tester.pumpWidget(
          MaterialApp(theme: AppTheme.light(), home: const DiaryScreen()),
        );
        await _pumpUntil(tester, find.byIcon(Icons.chevron_left));
        final today = DateTime.now();
        final yesterday = DateTime(today.year, today.month, today.day - 1);
        final fileName = 'G${_dateLabel(yesterday)}.md';

        store
          ..failBody = true
          ..throwOnBody = throws;
        await tester.enterText(find.byType(TextField), '还没有落盘的正文');
        await tester.tap(find.byTooltip('浏览远程日记'));
        await _pumpUntil(tester, find.text(fileName));
        expect(find.text(fileName), findsOneWidget);
        await tester.tap(find.text(fileName));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            '还没有落盘的正文');
        expect(find.text(_dateLabel(today)), findsOneWidget);
        expect(find.textContaining('本地保存失败'), findsWidgets);

        // 存储恢复后，重新打开同一文件可以正常切换。
        store.failBody = false;
        await tester.tap(find.byTooltip('浏览远程日记'));
        await _pumpUntil(tester, find.text(fileName));
        await tester.tap(find.text(fileName));
        await _pumpUntil(tester, find.text(_dateLabel(yesterday)));
        expect(find.text(_dateLabel(yesterday)), findsOneWidget);
        expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            contains('远端正文'));
        expect(tester.takeException(), isNull);
      }, () {
        final today = DateTime.now();
        final yesterday = DateTime(today.year, today.month, today.day - 1);
        final fileName = 'G${_dateLabel(yesterday)}.md';
        return MockClient((request) async {
          if (request.url.path.contains('/git/trees/')) {
            return http.Response(
              jsonEncode({
                'tree': [
                  {'path': fileName, 'type': 'blob', 'sha': 'remote-sha'},
                ],
                'truncated': false,
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'sha': 'remote-sha',
              'content': base64Encode(utf8.encode('远端正文')),
            }),
            200,
          );
        });
      });
    });
  }

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
