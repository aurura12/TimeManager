import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/screens/add_check_in_goal_screen.dart';
import 'package:time_manager/services/check_in_reminder_service.dart';
import 'package:time_manager/services/reminder_platform.dart';

import 'support/fake_reminder_backend.dart';

/// 打卡目标编辑页里的提醒入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeReminderBackend backend;

  CheckInGoal existingGoal(String id) => CheckInGoal(
        id: id,
        ownerId: 'manual-g',
        ownerEmail: 'guai@example.com',
        name: '早睡',
        description: '',
        color: const Color(0xFF96B462),
        icon: Icons.bedtime,
        period: CheckInPeriod.daily,
        targetCount: 1,
      );

  Future<void> pumpScreen(WidgetTester tester, {CheckInGoal? goal}) async {
    // 表单是长 ListView，视口给足高度，否则提醒分区在折叠线以下不会挂载
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: AddCheckInGoalScreen(goal: goal)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CheckInReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();

    backend = FakeReminderBackend();
    ReminderPlatform.backendOverride = backend;
    ReminderPlatform.androidPlatformOverride = true;
    ReminderPlatform.timezoneIdentifierOverride = () async => 'Asia/Shanghai';
  });

  tearDown(() {
    CheckInReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
  });

  testWidgets('显示提醒分区，默认开启前时间项不可点', (tester) async {
    await pumpScreen(tester);

    expect(find.text('提醒'), findsOneWidget);
    expect(find.text('打卡提醒'), findsOneWidget);
    expect(find.text('提醒时间'), findsOneWidget);
    expect(find.text('21:00'), findsOneWidget);

    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '提醒时间'),
    );
    expect(tile.enabled, isFalse, reason: '开关没打开时不该能改时间');
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开开关后可改时间，点开的是滚轮面板', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.widgetWithText(SwitchListTile, '打卡提醒'));
    await tester.pump();

    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '提醒时间'),
    );
    expect(tile.enabled, isTrue);

    await tester.tap(find.text('提醒时间'));
    await tester.pumpAndSettle();

    // 自研滚轮面板，而不是系统时钟表盘
    expect(find.byKey(const ValueKey('time-wheel-hour')), findsOneWidget);
    expect(find.byKey(const ValueKey('time-wheel-minute')), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('time-wheel-hour')),
      const Offset(0, -44),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('22:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑已有目标时读回本机保存的提醒设置', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'check_in_reminder_ids': '{"g1":2200}',
      'check_in_reminder_g1_enabled': true,
      'check_in_reminder_g1_hour': 8,
      'check_in_reminder_g1_minute': 30,
      'check_in_reminder_g1_name': '早睡',
    });

    await pumpScreen(tester, goal: existingGoal('g1'));

    expect(find.text('08:30'), findsOneWidget);
    final switchTile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '打卡提醒'),
    );
    expect(switchTile.value, isTrue);
  });

  testWidgets('新目标默认不带提醒', (tester) async {
    await pumpScreen(tester);

    final switchTile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '打卡提醒'),
    );
    expect(switchTile.value, isFalse);
  });

  testWidgets('非 Android 平台不渲染提醒分区', (tester) async {
    ReminderPlatform.androidPlatformOverride = false;

    await pumpScreen(tester);

    expect(find.text('提醒'), findsNothing);
    expect(find.text('打卡提醒'), findsNothing);
    expect(find.text('提醒时间'), findsNothing);
    expect(find.text('21:00'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非 Android 平台保存目标不会提示「不支持提醒」', (tester) async {
    ReminderPlatform.androidPlatformOverride = false;
    CheckInGoal? saved;
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                saved = await Navigator.of(context).push<CheckInGoal>(
                  MaterialPageRoute(
                    builder: (_) => const AddCheckInGoalScreen(),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '晨跑');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(find.textContaining('不支持'), findsNothing);
    expect(backend.calls, isEmpty, reason: '没有提醒能力的平台不该碰原生接口');
  });
}
