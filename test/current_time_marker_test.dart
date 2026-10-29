import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/utils/timeline_geometry.dart';
import 'package:time_manager/widgets/time_grid.dart';

Future<TimeProvider> _pumpGrid(
  WidgetTester tester, {
  required DateTime Function() clock,
  DateTime? date,
  double initialOffset = 0,
}) async {
  SharedPreferences.setMockInitialValues({
    'categories': jsonEncode(<Object>[]),
    'daily_slots': jsonEncode(<String, Object>{}),
  });
  final provider = TimeProvider();
  final controller = ScrollController(initialScrollOffset: initialOffset);
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<TimeProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 600,
            child: TimeGrid(
              gridKey: GlobalKey(),
              controller: controller,
              date: date,
              clock: clock,
              dragStartIndex: null,
              dragEndIndex: null,
              onTapDown: (_) {},
              onPanStart: (_) {},
              onPanUpdate: (_) {},
              onRemoveSlot: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
  return provider;
}

void main() {
  testWidgets('今天这一列显示「现在」标记，位置按分钟插值', (tester) async {
    final now = DateTime(2026, 10, 29, 10, 20);
    await _pumpGrid(tester, clock: () => now);

    final marker = find.byKey(const ValueKey('current-time-marker'));
    expect(marker, findsOneWidget);

    final gridRect = tester.getRect(find.byType(TimeGrid));
    final center = tester.getCenter(marker);
    final expectedY = gridRect.top +
        timelineYForMinutes(10 * 60 + 20,
            rowExtent: AppSizes.gridRow, topPadding: AppSpacing.sm);
    expect(center.dy, closeTo(expectedY, 0.5));
  });

  testWidgets('不是今天的列不画标记', (tester) async {
    final now = DateTime(2026, 10, 29, 10, 20);
    await _pumpGrid(
      tester,
      clock: () => now,
      date: now.add(const Duration(days: 1)),
    );
    expect(find.byKey(const ValueKey('current-time-marker')), findsNothing);
  });

  testWidgets('滚动后标记跟着内容移动', (tester) async {
    final now = DateTime(2026, 10, 29, 10, 20);
    await _pumpGrid(tester, clock: () => now, initialOffset: 120);
    final marker = find.byKey(const ValueKey('current-time-marker'));
    final gridRect = tester.getRect(find.byType(TimeGrid));
    final expectedY = gridRect.top +
        timelineYForMinutes(10 * 60 + 20,
            rowExtent: AppSizes.gridRow, topPadding: AppSpacing.sm) -
        120;
    expect(tester.getCenter(marker).dy, closeTo(expectedY, 0.5));
  });

  testWidgets('标记不拦点击：点它所在的行仍会选中槽位', (tester) async {
    final now = DateTime(2026, 10, 29, 10, 20);
    final taps = <Offset>[];
    SharedPreferences.setMockInitialValues({
      'categories': jsonEncode(<Object>[]),
      'daily_slots': jsonEncode(<String, Object>{}),
    });
    final provider = TimeProvider();
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<TimeProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 600,
              child: TimeGrid(
                gridKey: GlobalKey(),
                controller: controller,
                clock: () => now,
                dragStartIndex: null,
                dragEndIndex: null,
                onTapDown: taps.add,
                onPanStart: (_) {},
                onPanUpdate: (_) {},
                onRemoveSlot: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();

    final marker = find.byKey(const ValueKey('current-time-marker'));
    expect(marker, findsOneWidget);
    await tester.tapAt(tester.getCenter(marker));
    // 行内同时挂了双击识别器，单击要等双击判定窗口过去才回调 onTapDown。
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, isNotEmpty);
  });
}
