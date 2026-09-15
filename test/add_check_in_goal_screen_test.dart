import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/screens/add_check_in_goal_screen.dart';

void main() {
  testWidgets('预览会随输入和打卡要求即时更新', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: AddCheckInGoalScreen()),
    );
    await tester.pump();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '晨跑');
    await tester.enterText(fields.at(1), '每天出门跑步');
    await tester.tap(find.text('每周'));
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == '晨跑',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == '每天出门跑步',
      ),
      findsOneWidget,
    );
    expect(find.text('每周 1 次'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pump();

    expect(find.text('照片可选'), findsOneWidget);
    expect(find.text('不记录位置'), findsOneWidget);
  });

  testWidgets('图标和主题色选项具有语义标签且触控区域至少 48 像素', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: AddCheckInGoalScreen()),
    );
    await tester.pump();

    final iconFinder = find.bySemanticsLabel('图标：跑步');
    final colorFinder = find.bySemanticsLabel('主题色：橙色');
    expect(iconFinder, findsOneWidget);
    expect(colorFinder, findsOneWidget);
    expect(tester.getSize(iconFinder), const Size(48, 48));
    expect(tester.getSize(colorFinder), const Size(48, 48));
  });
}
