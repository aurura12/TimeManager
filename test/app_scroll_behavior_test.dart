import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/theme/app_scroll_behavior.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/time_grid.dart';

class _Result {
  Widget? widget;
  Object? error;
}

Future<_Result> _buildScrollbar(
  WidgetTester tester, {
  required TargetPlatform platform,
  required ScrollController? controller,
}) async {
  final result = _Result();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Builder(
        builder: (context) {
          try {
            result.widget = const AppScrollBehavior().buildScrollbar(
              context,
              const SizedBox.shrink(),
              ScrollableDetails(
                direction: AxisDirection.down,
                controller: controller,
              ),
            );
          } catch (error) {
            result.error = error;
          }
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return result;
}

Future<TimeProvider> _pumpGrid(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'categories': <String>[],
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
        scrollBehavior: const AppScrollBehavior(),
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
  testWidgets('桌面平台返回常显滚动条', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      final result = await _buildScrollbar(
        tester,
        platform: platform,
        controller: controller,
      );
      expect(result.error, isNull);
      final bar = result.widget! as Scrollbar;
      expect(bar.thumbVisibility, isTrue);
      expect(bar.controller, same(controller));
    }
  });

  testWidgets('移动平台不额外加滚动条', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      final result = await _buildScrollbar(
        tester,
        platform: platform,
        controller: controller,
      );
      expect(result.error, isNull);
      expect(result.widget, isA<SizedBox>());
    }
  });

  testWidgets('拿不到 controller 时退回不画，不抛断言', (tester) async {
    final result = await _buildScrollbar(
      tester,
      platform: TargetPlatform.macOS,
      controller: null,
    );
    expect(result.error, isNull);
    expect(result.widget, isA<SizedBox>());
  });

  testWidgets('时间网格列不会画出滚动条', (tester) async {
    await _pumpGrid(tester);
    expect(find.byType(Scrollbar), findsNothing);
  });
}
