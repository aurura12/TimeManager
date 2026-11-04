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

DateTime _dayOf(DateTime time) => DateTime(time.year, time.month, time.day);

Future<TimeProvider> _pumpGrid(
  WidgetTester tester, {
  required DateTime Function() clock,
  DateTime? date,
  double initialOffset = 0,
  ValueChanged<Offset>? onTapDown,
}) async {
  SharedPreferences.setMockInitialValues({
    // 分类按 getStringList 读取，塞 JSON 字符串会抛类型转换错误。
    'categories': <String>[],
    'daily_slots': jsonEncode(<String, Object>{}),
  });
  final provider = TimeProvider();
  final controller = ScrollController(initialScrollOffset: initialOffset);
  addTearDown(controller.dispose);
  // 不传 date 时用注入时钟的当天：TimeGrid 会回落到 provider.currentDate
  // （真实今天），否则测试只在「写死的日期正好是跑测试那天」时通过。
  final gridDate = date ?? _dayOf(clock());

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
              date: gridDate,
              clock: clock,
              dragStartIndex: null,
              dragEndIndex: null,
              onTapDown: onTapDown ?? (_) {},
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
  testWidgets('今天这一列显示「现在」标记，落在当前 10 分钟格子内', (tester) async {
    final now = DateTime(2026, 10, 29, 10, 20);
    await _pumpGrid(tester, clock: () => now);

    final marker = find.byKey(const ValueKey('current-time-marker'));
    expect(marker, findsOneWidget);

    final gridRect = tester.getRect(find.byType(TimeGrid));
    final center = tester.getCenter(marker);
    // 纵向贴 10:00 这一行的底边，不压住行内居中的事件名
    final expectedY = gridRect.top +
        timelineYForMinutes(11 * 60,
            rowExtent: AppSizes.gridRow, topPadding: AppSpacing.sm) -
        AppSizes.nowMarkerSize / 2;
    expect(center.dy, closeTo(expectedY, 0.5));
    // 20 分 → 落在 20–30 分那一格里，而不是行首
    final expectedX = gridRect.left +
        timelineXForMinute(20, rowWidth: gridRect.width);
    expect(center.dx, closeTo(expectedX, 0.5));
  });

  testWidgets('分钟不同落在不同格子，不再固定在第一个格', (tester) async {
    final now = DateTime(2026, 10, 29, 10, 45);
    await _pumpGrid(tester, clock: () => now);

    final marker = find.byKey(const ValueKey('current-time-marker'));
    final gridRect = tester.getRect(find.byType(TimeGrid));
    final columnWidth = gridRect.width / slotsPerHour;
    final center = tester.getCenter(marker);

    // 45 分属于第 5 格（40–50 分）
    expect(
      center.dx,
      closeTo(gridRect.left + columnWidth * 4.5, 0.5),
    );
    expect(center.dx, greaterThan(gridRect.left + columnWidth * 4));
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
        timelineYForMinutes(11 * 60,
            rowExtent: AppSizes.gridRow, topPadding: AppSpacing.sm) -
        AppSizes.nowMarkerSize / 2 -
        120;
    expect(tester.getCenter(marker).dy, closeTo(expectedY, 0.5));
  });

  testWidgets('标记不拦点击：点它所在的行仍会选中槽位', (tester) async {
    final now = DateTime(2026, 10, 29, 10, 20);
    final taps = <Offset>[];
    await _pumpGrid(tester, clock: () => now, onTapDown: taps.add);

    final marker = find.byKey(const ValueKey('current-time-marker'));
    expect(marker, findsOneWidget);
    await tester.tapAt(tester.getCenter(marker));
    // 行内同时挂了双击识别器，单击要等双击判定窗口过去才回调 onTapDown。
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, isNotEmpty);
  });
}
