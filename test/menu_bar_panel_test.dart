import 'package:material_ui/material_ui.dart';
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
  Widget child, {
  double width = 400,
  double height = 720,
  ThemeData? theme,
}) async {
  // 默认视口 800×600 会把 720 高的面板夹掉，坐标断言就不稳了。
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
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
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9, 5),
        grid: _fakeGrid(),
        onOpenMainWindow: () => opened++,
        onOpenSettings: () => settings++,
        onQuit: () => quit++,
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
    await tester.pump();

    expect(opened, 1);
    expect(settings, 1);
    expect(quit, 1);
    expect(find.byTooltip('精细添加（名称 / 精确起止）'), findsNothing);
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
        onClearSelection: () => cleared++,
      ),
    );

    expect(find.text('已选 09:00-09:20 · 滚轮选事件，停下即记录'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-dial')), findsOneWidget);

    await tester.tap(find.text('清除'));
    await tester.pump();
    expect(cleared, 1);
  });

  testWidgets('只读时显示原因', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        grid: _fakeGrid(),
        blockedReason: '远程视图只读，修改已忽略',
      ),
    );

    expect(find.text('远程视图只读，修改已忽略'), findsOneWidget);
  });

  testWidgets('转盘浮层叠在网格上，不占网格高度', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        grid: _fakeGrid(),
        selectionStart: 12,
        selectionEnd: 13,
      ),
    );
    final withoutDial = tester.getSize(find.byKey(const ValueKey('fake-grid')));

    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        grid: _fakeGrid(),
        dial: _fakeDial(),
        gridScroll: ValueNotifier<double>(0),
        selectionStart: 12,
        selectionEnd: 13,
      ),
    );
    final withDial = tester.getSize(find.byKey(const ValueKey('fake-grid')));

    expect(withDial, withoutDial);
    expect(find.byKey(const ValueKey('fake-dial')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('浮层跟着网格滚动走，选区滚出视口后隐藏', (tester) async {
    final scroll = ValueNotifier<double>(0);
    addTearDown(scroll.dispose);
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        grid: _fakeGrid(),
        dial: _fakeDial(),
        gridScroll: scroll,
        selectionStart: 12,
        selectionEnd: 13,
      ),
    );
    final gridRect = tester.getRect(find.byKey(const ValueKey('fake-grid')));
    final dialRect = tester.getRect(find.byKey(const ValueKey('fake-dial')));
    expect(gridRect.contains(dialRect.topLeft), isTrue);
    expect(gridRect.contains(dialRect.bottomRight), isTrue);
    expect(find.textContaining('已选 02:00-02:20'), findsOneWidget);

    scroll.value = 20;
    await tester.pump();
    expect(
      tester.getRect(find.byKey(const ValueKey('fake-dial'))).top,
      closeTo(dialRect.top - 20, 0.01),
    );

    // 选区整段滚出视口：浮层不画，但 hint 行仍显示时间段。
    scroll.value = 4000;
    await tester.pump();
    expect(find.byKey(const ValueKey('fake-dial')), findsNothing);
    expect(find.textContaining('已选 02:00-02:20'), findsOneWidget);
  });

  testWidgets('浮层底色保持不透明（壁纸模式下也不透）', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        grid: _fakeGrid(),
        dial: _fakeDial(),
        gridScroll: ValueNotifier<double>(0),
        selectionStart: 12,
        selectionEnd: 13,
      ),
      theme: AppTheme.light(backgroundEnabled: true),
    );
    final material = tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('fake-dial')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color?.a, 1.0);
  });

  testWidgets('小视口（400×560）里浮层仍落在网格区域内', (tester) async {
    await _pump(
      tester,
      MenuBarPanelView(
        summary: MenuBarSummary.empty,
        now: DateTime(2026, 11, 10, 9),
        grid: _fakeGrid(),
        dial: _fakeDial(),
        gridScroll: ValueNotifier<double>(0),
        selectionStart: 12,
        selectionEnd: 13,
      ),
      height: 560,
    );
    final gridRect = tester.getRect(find.byKey(const ValueKey('fake-grid')));
    final dialRect = tester.getRect(find.byKey(const ValueKey('fake-dial')));
    expect(gridRect.contains(dialRect.topLeft), isTrue);
    expect(gridRect.contains(dialRect.bottomRight), isTrue);
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
        grid: _fakeGrid(),
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
