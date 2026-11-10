import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/utils/menu_bar_summary.dart';
import 'package:time_manager/widgets/menu_bar_panel.dart';

TimeSlot _slot(int hour, int minute10, String label) {
  return TimeSlot(
    hour: hour,
    minute10: minute10,
    recorded: true,
    label: label,
    categoryId: 'c1',
    color: const Color(0xFF4DA8EE),
  );
}

List<TimeSlot> _day(List<TimeSlot> recorded) {
  final slots = <TimeSlot>[];
  for (var hour = 0; hour < 24; hour++) {
    for (var minute10 = 0; minute10 < 6; minute10++) {
      TimeSlot? match;
      for (final slot in recorded) {
        if (slot.hour == hour && slot.minute10 == minute10) {
          match = slot;
          break;
        }
      }
      slots.add(match ?? TimeSlot(hour: hour, minute10: minute10));
    }
  }
  return slots;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 400, height: 720, child: child),
        ),
      ),
    ),
  );
}

Widget _fakeGrid() => const SizedBox.expand(key: ValueKey('fake-grid'));
Widget _fakeDial() => const SizedBox(
      key: ValueKey('fake-dial'),
      height: 132,
    );

void main() {
  testWidgets('没有选区时不显示转盘，提示拖选', (tester) async {
    var opened = 0;
    var settings = 0;
    var quit = 0;
    var add = 0;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9, 5),
        grid: _fakeGrid(),
        canEdit: true,
        onOpenMainWindow: () => opened++,
        onOpenSettings: () => settings++,
        onQuit: () => quit++,
        onPreciseAdd: () => add++,
      ),
    );

    expect(find.text('11月10日 周二'), findsOneWidget);
    expect(find.text('今日已记录 0分钟'), findsOneWidget);
    expect(find.text('在格子上拖选一段（或点一格），松手后拨动事件'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-dial')), findsNothing);

    await tester.tap(find.text('打开主窗口'));
    await tester.tap(find.byTooltip('设置'));
    await tester.tap(find.byTooltip('退出时间块'));
    await tester.tap(find.byTooltip('精细添加（名称 / 精确起止）'));
    await tester.pump();

    expect(opened, 1);
    expect(settings, 1);
    expect(quit, 1);
    expect(add, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中后显示范围、转盘与清除入口', (tester) async {
    var cleared = 0;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        grid: _fakeGrid(),
        dial: _fakeDial(),
        selectionStart: 54,
        selectionEnd: 55,
        canEdit: true,
        onClearSelection: () => cleared++,
      ),
    );

    expect(find.text('已选 09:00-09:20 · 滚轮选事件，停下即记录'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-dial')), findsOneWidget);

    await tester.tap(find.text('清除'));
    await tester.pump();
    expect(cleared, 1);
  });

  testWidgets('只读时显示原因并禁用精细添加', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        grid: _fakeGrid(),
        blockedReason: '远程视图只读，修改已忽略',
        canEdit: false,
        onPreciseAdd: () {},
      ),
    );

    expect(find.text('远程视图只读，修改已忽略'), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('有记录时显示今日合计', (tester) async {
    final summary = buildMenuBarSummary(
      slots: _day([_slot(9, 0, '工作'), _slot(9, 1, '工作')]),
      now: DateTime(2026, 11, 10, 9, 10),
    );
    await _pump(
      tester,
      MenuBarPanelView(
        summary: summary,
        now: DateTime(2026, 11, 10, 9, 10),
        grid: _fakeGrid(),
        canEdit: true,
      ),
    );

    expect(find.text('今日已记录 20分钟'), findsOneWidget);
  });

  testWidgets('没有 TimeProvider 时显示加载态', (tester) async {
    await _pump(tester, const MenuBarPanel());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-bar-time-grid')), findsNothing);
  });
}
