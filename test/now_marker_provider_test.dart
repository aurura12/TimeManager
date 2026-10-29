import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/now_marker_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/time_grid.dart';

Future<void> _pumpGrid(
  WidgetTester tester,
  NowMarkerProvider marker,
) async {
  SharedPreferences.setMockInitialValues({
    'categories': <String>[],
    'daily_slots': jsonEncode(<String, Object>{}),
  });
  final provider = TimeProvider();
  final controller = ScrollController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<TimeProvider>.value(value: provider),
        ChangeNotifierProvider<NowMarkerProvider?>.value(value: marker),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: TimeGrid(
              gridKey: GlobalKey(),
              controller: controller,
              dragStartIndex: null,
              dragEndIndex: null,
              onTapDown: (_) {},
              onPanStart: (_) {},
              onPanUpdate: (_) {},
              onRemoveSlot: (_) {},
              // 固定到凌晨 2 点，保证标记落在 400px 视口内。
              clock: () {
                final today = DateTime.now();
                return DateTime(today.year, today.month, today.day, 2);
              },
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
}

void main() {
  group('NowMarkerProvider', () {
    test('默认显示', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = NowMarkerProvider();
      await provider.ready;
      expect(provider.enabled, isTrue);
    });

    test('关闭后落盘，重新读取仍是关闭', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = NowMarkerProvider();
      await provider.ready;
      await provider.setEnabled(false);
      expect(provider.enabled, isFalse);

      final reloaded = NowMarkerProvider();
      await reloaded.ready;
      expect(reloaded.enabled, isFalse, reason: '开关要能跨启动保留');
    });

    test('脏数据回落为显示', () async {
      SharedPreferences.setMockInitialValues(
        {NowMarkerProvider.storageKey: 'not-a-bool'},
      );
      final provider = NowMarkerProvider();
      await provider.ready;
      expect(provider.enabled, isTrue);
    });
  });

  testWidgets('关闭开关后网格不再显示标记，打开后恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final marker = NowMarkerProvider();
    await marker.ready;

    await _pumpGrid(tester, marker);
    final dot = find.byKey(const ValueKey('current-time-marker'));
    expect(dot, findsOneWidget);

    await marker.setEnabled(false);
    await tester.pump();
    expect(dot, findsNothing);

    await marker.setEnabled(true);
    await tester.pump();
    expect(dot, findsOneWidget);
  });
}
