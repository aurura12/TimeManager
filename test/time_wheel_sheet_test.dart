import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/time_wheel_sheet.dart';

/// 滚轮时间面板。要点是"打开即定位到当前值、滚动立即反映到预览、确定才落值"。
void main() {
  late TimeOfDay? picked;
  late bool completed;

  Future<void> pumpHost(WidgetTester tester, TimeOfDay initial) async {
    picked = null;
    completed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await showTimeWheelSheet(
                    context,
                    initialTime: initial,
                    title: '提醒时间',
                  );
                  completed = true;
                },
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();
  }

  testWidgets('打开后显示标题、当前值与两个滚轮', (tester) async {
    await pumpHost(tester, const TimeOfDay(hour: 21, minute: 0));

    expect(find.text('提醒时间'), findsOneWidget);
    expect(find.text('21:00'), findsOneWidget);
    expect(find.byKey(const ValueKey('time-wheel-hour')), findsOneWidget);
    expect(find.byKey(const ValueKey('time-wheel-minute')), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('初始值不是整点时也定位正确', (tester) async {
    await pumpHost(tester, const TimeOfDay(hour: 8, minute: 30));

    expect(find.text('08:30'), findsOneWidget);
  });

  testWidgets('取消返回 null，不产生新值', (tester) async {
    await pumpHost(tester, const TimeOfDay(hour: 21, minute: 0));

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(picked, isNull);
    expect(find.text('21:00'), findsNothing);
  });

  testWidgets('不做任何调整直接确定，返回原值', (tester) async {
    await pumpHost(tester, const TimeOfDay(hour: 21, minute: 5));

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(picked, const TimeOfDay(hour: 21, minute: 5));
  });

  testWidgets('滚动小时滚轮会同步更新预览，确定后返回新值', (tester) async {
    await pumpHost(tester, const TimeOfDay(hour: 21, minute: 0));

    await tester.drag(
      find.byKey(const ValueKey('time-wheel-hour')),
      const Offset(0, -44),
    );
    await tester.pumpAndSettle();

    // 预览必须立刻跟着变，而不是等确定才刷新
    expect(find.text('22:00'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(picked, const TimeOfDay(hour: 22, minute: 0));
  });

  testWidgets('滚动分钟滚轮独立生效，不影响小时', (tester) async {
    await pumpHost(tester, const TimeOfDay(hour: 21, minute: 0));

    await tester.drag(
      find.byKey(const ValueKey('time-wheel-minute')),
      const Offset(0, -44),
    );
    await tester.pumpAndSettle();

    expect(find.text('21:01'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(picked, const TimeOfDay(hour: 21, minute: 1));
  });

  testWidgets('面板没有溢出，浅色深色都能渲染', (tester) async {
    for (final theme in <ThemeData>[AppTheme.light(), AppTheme.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showTimeWheelSheet(
                    context,
                    initialTime: const TimeOfDay(hour: 23, minute: 59),
                  ),
                  child: const Text('打开面板'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();
      expect(find.text('23:59'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 必须先关掉：换主题时 Navigator 状态会被复用，面板不关下一轮点击就落不到按钮上
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }
  });
}
