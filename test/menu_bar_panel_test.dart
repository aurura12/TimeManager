import 'package:flutter/gestures.dart';
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
          child: SizedBox(width: 400, height: 560, child: child),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('空数据也能看到时间轴与分类', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9, 5),
        loading: false,
        categories: _categories,
        canEdit: true,
        onSelectCategory: (_) {},
        onTapCell: (_) {},
        onPaintRange: (_, __) {},
      ),
    );

    expect(find.text('11月10日 周二'), findsOneWidget);
    expect(find.text('今日已记录 0分钟'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-bar-time-grid')), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '工作'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '休息'), findsOneWidget);
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
        loading: false,
        categories: _categories,
        canEdit: true,
      ),
    );

    expect(find.text('今日已记录 20分钟'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-bar-time-grid')), findsOneWidget);
  });

  testWidgets('点分类会回调并显示子事件', (tester) async {
    Category? picked;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        loading: false,
        categories: _categories,
        selectedCategoryId: 'c1',
        canEdit: true,
        onSelectCategory: (category) => picked = category,
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '休息'));
    await tester.pump();
    expect(picked?.id, 'c2');

    expect(find.widgetWithText(ChoiceChip, '开会'), findsOneWidget);
  });

  testWidgets('只读时禁用分类并显示原因', (tester) async {
    var picked = 0;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        loading: false,
        categories: _categories,
        blockedReason: '远程视图只读，修改已忽略',
        canEdit: false,
        onSelectCategory: (_) => picked++,
      ),
    );

    expect(find.text('远程视图只读，修改已忽略'), findsOneWidget);
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '工作'),
    );
    expect(chip.onSelected, isNull);
    expect(picked, 0);
  });

  testWidgets('没有分类时给出入口说明', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        loading: false,
        categories: const <Category>[],
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
        loading: false,
        categories: _categories,
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

  testWidgets('在时间轴上拖动会回报选中范围', (tester) async {
    int? start;
    int? end;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        loading: false,
        categories: _categories,
        canEdit: true,
        onPaintRange: (from, to) {
          start = from;
          end = to;
        },
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey('menu-bar-time-grid')),
      const Offset(0, 60),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(start, isNotNull);
    expect(end, isNotNull);
    expect(end!, greaterThanOrEqualTo(start!));
  });

  testWidgets('加载中不渲染时间轴', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        loading: true,
        categories: _categories,
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-bar-time-grid')), findsNothing);
  });
}
