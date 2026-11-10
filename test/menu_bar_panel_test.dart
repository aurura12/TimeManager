import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/category.dart';
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

final _categories = <Category>[
  Category(id: 'c1', name: '工作', color: const Color(0xFF4DA8EE), subCategories: ['开会']),
  Category(id: 'c2', name: '休息', color: const Color(0xFF96B462)),
];

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

Widget _fakeGrid() => const SizedBox.expand(
      key: ValueKey('fake-grid'),
    );

void main() {
  testWidgets('空数据也能看到外壳与分类', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9, 5),
        categories: _categories,
        grid: _fakeGrid(),
        canEdit: true,
        onWriteTarget: (_, __) {},
      ),
    );

    expect(find.text('11月10日 周二'), findsOneWidget);
    expect(find.text('今日已记录 0分钟'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-grid')), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '工作'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '开会'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '休息'), findsOneWidget);
    expect(find.text('在格子上拖选一段（或点一格），再点分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
        categories: _categories,
        grid: _fakeGrid(),
        canEdit: true,
      ),
    );

    expect(find.text('今日已记录 20分钟'), findsOneWidget);
  });

  testWidgets('选中范围后点分类/子事件会回报写入目标', (tester) async {
    final writes = <({Category category, String? subLabel})>[];
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        categories: _categories,
        grid: _fakeGrid(),
        selectionStart: 54,
        selectionEnd: 55,
        canEdit: true,
        onWriteTarget: (category, subLabel) =>
            writes.add((category: category, subLabel: subLabel)),
      ),
    );

    expect(find.text('已选 09:00-09:20 · 点分类写入'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, '工作'));
    await tester.tap(find.widgetWithText(ActionChip, '开会'));
    await tester.pump();

    expect(writes, hasLength(2));
    expect(writes.first.category.id, 'c1');
    expect(writes.first.subLabel, isNull);
    expect(writes.last.subLabel, '开会');
  });

  testWidgets('只读时禁用分类并显示原因', (tester) async {
    var wrote = 0;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        categories: _categories,
        grid: _fakeGrid(),
        blockedReason: '远程视图只读，修改已忽略',
        canEdit: false,
        onWriteTarget: (_, __) => wrote++,
      ),
    );

    expect(find.text('远程视图只读，修改已忽略'), findsOneWidget);
    final chip = tester.widget<ActionChip>(
      find.widgetWithText(ActionChip, '工作'),
    );
    expect(chip.onPressed, isNull);
    expect(wrote, 0);
  });

  testWidgets('没有分类时给出入口说明', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        categories: const <Category>[],
        grid: _fakeGrid(),
        canEdit: true,
      ),
    );

    expect(find.text('还没有分类，请先在主窗口里添加'), findsOneWidget);
  });

  testWidgets('底部按钮都会回调', (tester) async {
    var opened = 0;
    var settings = 0;
    var quit = 0;
    var add = 0;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        categories: _categories,
        grid: _fakeGrid(),
        canEdit: true,
        onOpenMainWindow: () => opened++,
        onOpenSettings: () => settings++,
        onQuit: () => quit++,
        onPreciseAdd: () => add++,
      ),
    );

    await tester.tap(find.text('打开主窗口'));
    await tester.tap(find.byTooltip('设置'));
    await tester.tap(find.byTooltip('退出时间块'));
    await tester.tap(find.byTooltip('精细添加（名称 / 精确起止）'));
    await tester.pump();

    expect(opened, 1);
    expect(settings, 1);
    expect(quit, 1);
    expect(add, 1);
  });

  testWidgets('没有 TimeProvider 时显示加载态', (tester) async {
    await _pump(tester, const MenuBarPanel());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-bar-time-grid')), findsNothing);
  });
}
