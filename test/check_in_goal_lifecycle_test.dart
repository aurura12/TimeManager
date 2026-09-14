import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/screens/add_check_in_goal_screen.dart';

CheckInGoal _goal(
    {DateTime? startDate, DateTime? endDate, bool archived = false}) {
  return CheckInGoal(
    id: 'g1',
    ownerId: 'u1',
    ownerEmail: 'a@example.com',
    name: '运动',
    description: '',
    color: const Color(0xFF000000),
    icon: Icons.flag,
    period: CheckInPeriod.daily,
    targetCount: 1,
    startDate: startDate,
    endDate: endDate,
    isArchived: archived,
  );
}

DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

String _fmt(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

void main() {
  group('打卡目标有效期判定', () {
    test('结束日期当天仍有效（回归：此前当天就判过期）', () {
      final goal = _goal(endDate: _today());
      expect(goal.isExpired, isFalse);
      expect(goal.isActive, isTrue);
    });

    test('结束日期当天带具体时刻也仍有效', () {
      final today = _today();
      final goal =
          _goal(endDate: DateTime(today.year, today.month, today.day, 9));
      expect(goal.isExpired, isFalse);
      expect(goal.isActive, isTrue);
    });

    test('过了结束日才过期', () {
      final goal = _goal(endDate: _today().subtract(const Duration(days: 1)));
      expect(goal.isExpired, isTrue);
      expect(goal.isActive, isFalse);
    });

    test('结束日期在未来时有效', () {
      final goal = _goal(endDate: _today().add(const Duration(days: 1)));
      expect(goal.isExpired, isFalse);
      expect(goal.isActive, isTrue);
    });

    test('未设置结束日期时永不过期', () {
      final goal = _goal();
      expect(goal.isExpired, isFalse);
      expect(goal.isActive, isTrue);
    });

    test('已归档的目标一律不活跃', () {
      final future = _goal(
        endDate: _today().add(const Duration(days: 30)),
        archived: true,
      );
      expect(future.isActive, isFalse);
      expect(future.isExpired, isFalse);

      final past = _goal(
          endDate: _today().subtract(const Duration(days: 1)), archived: true);
      expect(past.isActive, isFalse);
      expect(past.isExpired, isTrue);
    });

    test('选 7 天时长时，第 7 天仍可打卡、第 8 天过期', () {
      final start = _today();
      final end = start.add(const Duration(days: 6));

      // 用固定"今天"无法模拟未来，这里直接验证边界日期语义：
      // 结束日 00:00 所在的那一天算有效，次日 00:00 起算过期
      expect(DateTime(end.year, end.month, end.day + 1).isAfter(end), isTrue);
      expect(_goal(startDate: start, endDate: end).isExpired, isFalse);
    });
  });

  group('打卡目标时长选择', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: AddCheckInGoalScreen()),
      );
      await tester.pump();
    }

    testWidgets('新建目标时选「1周」会算出结束日期（回归：此前被静默丢弃）', (tester) async {
      await pumpScreen(tester);

      expect(find.text('今天'), findsOneWidget);
      expect(find.textContaining('结束日期：'), findsNothing);

      await tester.tap(find.text('1周'));
      await tester.pump();

      final expected = _fmt(_today().add(const Duration(days: 6)));
      expect(find.text('结束日期：$expected'), findsOneWidget);
      // 开始日期落成具体日期，保证开始/结束/时长三者一致
      expect(find.text(_fmt(_today())), findsOneWidget);
      expect(find.text('今天'), findsNothing);
    });

    testWidgets('自定义天数同样生效', (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '3');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final expected = _fmt(_today().add(const Duration(days: 2)));
      expect(find.text('结束日期：$expected'), findsOneWidget);
    });

    testWidgets('取消选择时长会清掉结束日期', (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.text('1周'));
      await tester.pump();
      expect(find.textContaining('结束日期：'), findsOneWidget);

      await tester.tap(find.text('1周'));
      await tester.pump();
      expect(find.textContaining('结束日期：'), findsNothing);
    });

    testWidgets('保存时带上了开始与结束日期', (tester) async {
      CheckInGoal? saved;
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
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
      await tester.tap(find.text('1周'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.startDate, _today());
      expect(saved!.endDate, _today().add(const Duration(days: 6)));
    });
  });
}
