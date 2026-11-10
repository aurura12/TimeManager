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

Future<void> _pump(
  WidgetTester tester,
  Widget child,
) async {
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
  testWidgets('空数据给出空态与引导', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9, 5),
        loading: false,
        onOpenMainWindow: () {},
        onOpenSettings: () {},
        onQuit: () {},
      ),
    );

    expect(find.text('11月10日 周二'), findsOneWidget);
    expect(find.text('今天还没有记录'), findsOneWidget);
    expect(find.text('点右上角「＋」补一段'), findsOneWidget);
  });

  testWidgets('展示今日分段与合计', (tester) async {
    final slots = _day([
      _slot(9, 0, '站会'),
      _slot(9, 1, '站会'),
      _slot(14, 0, '写方案'),
    ]);
    final summary = buildMenuBarSummary(
      slots: slots,
      now: DateTime(2026, 11, 10, 9, 10),
    );

    await _pump(
      tester,
      MenuBarPanelView(
        summary: summary,
        now: DateTime(2026, 11, 10, 9, 10),
        loading: false,
      ),
    );

    expect(find.text('站会'), findsOneWidget);
    expect(find.text('09:00-09:20'), findsOneWidget);
    expect(find.text('写方案'), findsOneWidget);
    expect(find.text('今日已记录 30分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点块与底部按钮都会回调', (tester) async {
    final slots = _day([_slot(9, 0, '站会')]);
    final summary = buildMenuBarSummary(
      slots: slots,
      now: DateTime(2026, 11, 10, 9),
    );
    MenuBarSpan? tapped;
    var opened = 0;
    var settings = 0;
    var quit = 0;

    await _pump(
      tester,
      MenuBarPanelView(
        summary: summary,
        now: DateTime(2026, 11, 10, 9),
        loading: false,
        onSpanTap: (span) => tapped = span,
        onOpenMainWindow: () => opened++,
        onOpenSettings: () => settings++,
        onQuit: () => quit++,
      ),
    );

    await tester.tap(find.text('站会'));
    await tester.pump();
    expect(tapped?.label, '站会');

    await tester.tap(find.text('打开主窗口'));
    await tester.pump();
    expect(opened, 1);

    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    expect(settings, 1);

    await tester.tap(find.byTooltip('退出时间块'));
    await tester.pump();
    expect(quit, 1);
  });

  testWidgets('有新增回调时显示两个入口', (tester) async {
    var added = 0;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        loading: false,
        onAdd: () => added++,
      ),
    );

    await tester.tap(find.byTooltip('新增日程'));
    await tester.pump();
    expect(added, 1);

    await tester.tap(find.text('补一段'));
    await tester.pump();
    expect(added, 2);
  });

  testWidgets('只读状态禁用新增并说明原因', (tester) async {
    var added = 0;
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        loading: false,
        onAdd: () => added++,
        addBlockedReason: '远程视图只读，修改已忽略',
      ),
    );

    expect(find.text('远程视图只读，修改已忽略'), findsOneWidget);
    await tester.tap(find.byTooltip('远程视图只读，修改已忽略'));
    await tester.pump();
    expect(added, 0);
  });

  testWidgets('加载中不闪空态', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        loading: true,
      ),
    );

    expect(find.text('今天还没有记录'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
