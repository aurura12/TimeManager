import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/time_slot_resize.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/event_label_text.dart';
import 'package:time_manager/widgets/time_grid.dart';

const _focusColor = 0xFF9CB86A;
const _otherColor = 0xFF5B8DEF;

final _focus = Category(
  id: 'focus',
  name: '专注',
  color: const Color(_focusColor),
  updatedAt: 1,
);

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _gridKey(DateTime date) =>
    '${date.year}-${date.month}-${date.day}';

void _installPluginMocks(Map<String, Object> prefs) {
  SharedPreferences.setMockInitialValues(prefs);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_grid_resize_test',
  );
}

Future<void> _pumpUntilReady(WidgetTester tester, TimeProvider provider) async {
  for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(provider.isInitialLoadFinished, isTrue, reason: 'TimeProvider 初始化未完成');
}

Future<void> _drainPendingSync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 5));
  await tester.pump();
}

class _Harness {
  _Harness(this.provider, this.requests, this.taps, this.pans);

  final TimeProvider provider;
  final List<TimeSlotResizeRequest> requests;
  final List<Offset> taps;
  final List<Offset> pans;
}

/// 网格视口 300×400，第一列宽 50，可见 0..8 点。
/// 00:00（索引 0）放「原始」，00:20（索引 2）放「相邻」，01:00（索引 6）放日历块。
Future<_Harness> _pumpGrid(
  WidgetTester tester, {
  bool readOnly = false,
  bool brushMode = false,
  int? dragStartIndex,
  int? dragEndIndex,
}) async {
  final today = DateTime.now();
  final dateKey = _dateKey(today);
  _installPluginMocks({
    'categories': [jsonEncode(_focus.toJson())],
    'daily_slots': jsonEncode({
      dateKey: [
        {'i': 0, 'l': '原始', 'cid': 'focus', 'c': _focusColor, 'ts': 1},
        {'i': 2, 'l': '相邻', 'cid': 'focus', 'c': _otherColor, 'ts': 1},
        {'i': 6, 'l': '日历', 'cid': 'focus', 'c': _focusColor, 'ts': 1, 'fc': true},
      ],
    }),
  });

  final provider = TimeProvider();
  final requests = <TimeSlotResizeRequest>[];
  final taps = <Offset>[];
  final pans = <Offset>[];
  final gridKey = GlobalKey();
  final scrollController = ScrollController();
  addTearDown(scrollController.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<TimeProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: TimeGrid(
              gridKey: gridKey,
              controller: scrollController,
              dragStartIndex: dragStartIndex,
              dragEndIndex: dragEndIndex,
              readOnly: readOnly,
              brushMode: brushMode,
              onResizeTimeBlock: (request) => requests.add(request),
              onTapDown: taps.add,
              onPanStart: pans.add,
              onPanUpdate: pans.add,
              onRemoveSlot: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await _pumpUntilReady(tester, provider);
  await tester.pump();
  return _Harness(provider, requests, taps, pans);
}

Finder _handle(DateTime date, String edge, int hour, int index) => find.byKey(
      ValueKey('grid-resize-$edge-${_gridKey(date)}:$hour:$index'),
    );

void main() {
  testWidgets('桌面鼠标拖右边缘：松手前只预览，松手后提交一次', (tester) async {
    final harness = await _pumpGrid(tester);
    final date = harness.provider.currentDate;

    final end = _handle(date, 'end', 0, 0);
    expect(end, findsOneWidget);

    final before = tester
        .widget<EventLabelText>(find.byType(EventLabelText).first)
        .detail;
    expect(before, contains('00:10'));

    final gesture = await tester.startGesture(
      tester.getCenter(end),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();

    expect(harness.requests, isEmpty, reason: '拖动过程中不能写数据');
    final preview = tester
        .widget<EventLabelText>(find.byType(EventLabelText).first)
        .detail;
    expect(preview, contains('00:20'), reason: '预览应立即拉长到 20 分钟');

    await gesture.up();
    await tester.pump();

    expect(harness.requests, hasLength(1));
    final request = harness.requests.single;
    expect(request.edge, TimeSlotResizeEdge.end);
    expect(request.targetIndex, 1);
    expect(request.expectedStart, 0);
    expect(request.expectedEnd, 0);
    expect(request.expectedLabel, '原始');
    expect(harness.taps, isEmpty, reason: '拖动不应触发点选');

    await _drainPendingSync(tester);
  });

  testWidgets('鼠标在把手上按一下不拖：仍然是普通点选', (tester) async {
    final harness = await _pumpGrid(tester);
    final date = harness.provider.currentDate;

    final gesture = await tester.startGesture(
      tester.getCenter(_handle(date, 'end', 0, 0)),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness.requests, isEmpty);
    expect(harness.taps, hasLength(1), reason: '没移动就不该吃掉点选');

    await _drainPendingSync(tester);
  });

  testWidgets('触摸未点选时不响应把手，点选后可以拖', (tester) async {
    final notSelected = await _pumpGrid(tester);
    final date = notSelected.provider.currentDate;

    final handleCenter = tester.getCenter(_handle(date, 'end', 0, 0));
    final first = await tester.startGesture(handleCenter);
    await first.moveBy(const Offset(50, 0));
    await tester.pump();
    await first.up();
    await tester.pump();

    expect(notSelected.requests, isEmpty, reason: '触摸必须先点选块');
    await _drainPendingSync(tester);

    final selected = await _pumpGrid(
      tester,
      dragStartIndex: 0,
      dragEndIndex: 0,
    );
    final second = await tester.startGesture(handleCenter);
    await second.moveBy(const Offset(50, 0));
    await tester.pump();
    await second.up();
    await tester.pump();

    expect(selected.requests, hasLength(1));
    expect(selected.requests.single.targetIndex, 1);

    await _drainPendingSync(tester);
  });

  testWidgets('纵向拖动整行按 6 格（1 小时）折算', (tester) async {
    final harness = await _pumpGrid(tester);
    final date = harness.provider.currentDate;

    final gesture = await tester.startGesture(
      tester.getCenter(_handle(date, 'end', 0, 0)),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await gesture.moveBy(const Offset(0, 45));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(harness.requests.single.targetIndex, 6);

    await _drainPendingSync(tester);
  });

  testWidgets('日历块、只读与刷子模式都不出现把手', (tester) async {
    final calendar = await _pumpGrid(tester);
    final date = calendar.provider.currentDate;
    expect(_handle(date, 'end', 1, 6), findsNothing);

    await _pumpGrid(tester, readOnly: true);
    expect(_handle(date, 'end', 0, 0), findsNothing);
    expect(_handle(date, 'start', 0, 0), findsNothing);

    await _pumpGrid(tester, brushMode: true);
    expect(_handle(date, 'end', 0, 0), findsNothing);

    await _drainPendingSync(tester);
  });

  testWidgets('把手使用左右拖动光标', (tester) async {
    final harness = await _pumpGrid(tester);
    final date = harness.provider.currentDate;

    final region = tester.widget<MouseRegion>(find.descendant(
      of: _handle(date, 'end', 0, 0),
      matching: find.byType(MouseRegion),
    ));
    expect(region.cursor, SystemMouseCursors.resizeLeftRight);

    await _drainPendingSync(tester);
  });
}
