import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/time_block_reminder_lead_sheet.dart';

Future<int?> openSheet(WidgetTester tester, {required int initial}) async {
  int? result;
  var opened = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                if (opened) return;
                opened = true;
                result = await showTimeBlockReminderLeadSheet(
                  context,
                  initialMinutes: initial,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('快捷档位覆盖准点到 30 分钟', (tester) async {
    await openSheet(tester, initial: 5);

    expect(find.text('提前多久提醒'), findsOneWidget);
    expect(find.text('准点'), findsOneWidget);
    expect(find.text('5 分钟'), findsOneWidget);
    expect(find.text('10 分钟'), findsOneWidget);
    expect(find.text('15 分钟'), findsOneWidget);
    expect(find.text('20 分钟'), findsOneWidget);
    expect(find.text('25 分钟'), findsOneWidget);
    expect(find.text('30 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点快捷档位后返回该分钟数', (tester) async {
    int? result;
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                if (opened) return;
                opened = true;
                result = await showTimeBlockReminderLeadSheet(
                  context,
                  initialMinutes: 5,
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

    await tester.tap(find.text('15 分钟'));
    await tester.pumpAndSettle();

    expect(result, 15);
  });

  testWidgets('自定义输入 0–30 合法，超出范围禁用确定', (tester) async {
    await openSheet(tester, initial: 5);

    await tester.enterText(find.byType(TextField), '7');
    await tester.pump();
    expect(find.text('请输入 0–30 之间的整数'), findsNothing);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await openSheet(tester, initial: 5);
    await tester.enterText(find.byType(TextField), '31');
    await tester.pump();
    expect(find.text('请输入 0–30 之间的整数'), findsOneWidget);
    final confirm = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(confirm.onPressed, isNull);
  });

  testWidgets('窄屏大字不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.3),
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTimeBlockReminderLeadSheet(
                context,
                initialMinutes: 5,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
