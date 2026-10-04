import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/travel_record.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/widgets/travel_date_details.dart';
import 'package:time_manager/widgets/travel_desktop_calendar.dart';
import 'package:time_manager/widgets/travel_tables.dart';

final _records = [
  TravelRecord(date: DateTime(2026, 10, 20), location: '北理', event: '图书馆、整理资料'),
  TravelRecord(date: DateTime(2026, 10, 15), location: '北航 北邮', event: '双选会'),
  TravelRecord(
      date: DateTime(2026, 10, 5), location: '杭州 西湖', event: '散步、吃饭，记录这一天的见闻'),
  TravelRecord(date: DateTime(2026, 10, 2), location: '上海', event: '出差、参观博物馆'),
  TravelRecord(date: DateTime(2026, 9, 30), location: '苏州', event: '上一月记录'),
];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1400, 900),
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  bool wallpaper = false,
  GlobalKey? boundaryKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final baseTheme = AppTheme.themeFor(brightness,
      backgroundEnabled: wallpaper, surfaceOpacity: 0.72);
  const previewFont = String.fromEnvironment('TRAVEL_UI_PREVIEW_FONT');
  final theme = previewFont.isEmpty
      ? baseTheme
      : baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'TravelPreview'),
          appBarTheme: baseTheme.appBarTheme.copyWith(
            titleTextStyle: baseTheme.appBarTheme.titleTextStyle
                ?.copyWith(fontFamily: 'TravelPreview'),
          ),
          textButtonTheme: TextButtonThemeData(
            style: baseTheme.textButtonTheme.style?.copyWith(
              textStyle: WidgetStatePropertyAll(
                  AppText.button.copyWith(fontFamily: 'TravelPreview')),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: baseTheme.filledButtonTheme.style?.copyWith(
              textStyle: WidgetStatePropertyAll(
                  AppText.button.copyWith(fontFamily: 'TravelPreview')),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: baseTheme.outlinedButtonTheme.style?.copyWith(
              textStyle: WidgetStatePropertyAll(
                  AppText.button.copyWith(fontFamily: 'TravelPreview')),
            ),
          ),
        );
  await tester.pumpWidget(RepaintBoundary(
    key: boundaryKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('出行')),
        body: Padding(padding: AppSpacing.cardComfortable, child: child),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const directory = String.fromEnvironment('TRAVEL_UI_PREVIEW_DIR');
  if (directory.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final picture = await boundary.toImage();
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}

Widget _calendar({
  required DateTime selectedDate,
  required ValueChanged<DateTime> onSelectDate,
  ValueChanged<int>? onChangeMonth,
  VoidCallback? onPickMonth,
  VoidCallback? onToday,
  VoidCallback? onAdd,
  VoidCallback? onEdit,
  VoidCallback? onDelete,
}) {
  final entry =
      _records.where((record) => record.date == selectedDate).firstOrNull;
  return TravelDesktopCalendar(
    month: DateTime(2026, 10),
    selectedDate: selectedDate,
    records: _records,
    selectedDateDetails: TravelDateDetails(
      date: selectedDate,
      record: entry,
      onAdd: onAdd ?? () {},
      onEdit: onEdit ?? () {},
      onDelete: onDelete ?? () {},
    ),
    onSelectDate: onSelectDate,
    onChangeMonth: onChangeMonth ?? (_) {},
    onPickMonth: onPickMonth ?? () {},
    onToday: onToday ?? () {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const font = String.fromEnvironment('TRAVEL_UI_PREVIEW_FONT');
    if (font.isEmpty) return;
    final loader = FontLoader('TravelPreview');
    loader.addFont(File(font).readAsBytes().then(ByteData.sublistView));
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('宽屏表格列之间留空，选中日期和操作菜单各自正确触发', (tester) async {
    DateTime? selected;
    String? action;
    final boundary = GlobalKey();
    await _pump(
        tester,
        TravelRecordTable(
          records: _records,
          selectedDateKey: '',
          onSelectDate: (date) => selected = date,
          actionsBuilder: (record) => PopupMenuButton<String>(
            tooltip: '操作${record.dateKey}',
            onSelected: (value) => action = value,
            itemBuilder: (_) =>
                const [PopupMenuItem(value: 'edit', child: Text('编辑'))],
          ),
        ),
        boundaryKey: boundary);
    final date = tester.getRect(find.text('2026-10-15'));
    final location = tester.getRect(find.text('北航 北邮'));
    expect(date.right, lessThan(location.left));
    expect(tester.getRect(find.text('地点')).left, location.left);
    await _capture(tester, boundary, 'travel_table');
    await tester.tap(find.text('北航 北邮'));
    expect(selected, DateTime(2026, 10, 15));
    selected = null;
    await tester.tap(find.byTooltip('操作2026-10-15'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(action, 'edit');
    expect(selected, isNull, reason: '菜单点击不能选中其它日期');
    expect(tester.takeException(), isNull);
  });

  testWidgets('月度表格的长地点可以换行，窄窗口大字不溢出', (tester) async {
    final boundary = GlobalKey();
    final table = TravelMonthlyTable(
      monthCounts: const [MapEntry('2026-10', 4), MapEntry('2026-09', 1)],
      locationsByMonth: {
        '2026-10': {'北京理工大学', '北京航空航天大学', '杭州西湖', '上海博物馆', '清华大学', '颐和园'},
        '2026-09': {'苏州'},
      },
    );
    await _pump(tester, SingleChildScrollView(child: table),
        boundaryKey: boundary);
    expect(tester.getRect(find.text('2026-10')).right,
        lessThan(tester.getRect(find.text('4')).left));
    await _capture(tester, boundary, 'travel_monthly_table');
    await _pump(tester, SingleChildScrollView(child: table),
        size: const Size(360, 640), textScaler: TextScaler.linear(1.8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('月历展示地点和事件，切日更新详情，月份和今天操作可用', (tester) async {
    var selected = DateTime(2026, 10, 5);
    final deltas = <int>[];
    var monthPickerCalls = 0;
    var todayCalls = 0;
    var editCalls = 0;
    var deleteCalls = 0;
    final boundary = GlobalKey();
    await _pump(
        tester,
        StatefulBuilder(
            builder: (context, setState) => _calendar(
                  selectedDate: selected,
                  onSelectDate: (date) => setState(() => selected = date),
                  onChangeMonth: deltas.add,
                  onPickMonth: () => monthPickerCalls++,
                  onToday: () => todayCalls++,
                  onEdit: () => editCalls++,
                  onDelete: () => deleteCalls++,
                )),
        boundaryKey: boundary);
    final day = find.byKey(const ValueKey('travel-calendar-day-2026-10-05'));
    expect(
        find.descendant(of: day, matching: find.text('杭州 西湖')), findsOneWidget);
    expect(find.descendant(of: day, matching: find.text(_records[2].event)),
        findsOneWidget);
    final calendarBounds =
        tester.getRect(find.byKey(const ValueKey('travel-desktop-month')));
    expect(calendarBounds.right,
        lessThan(tester.getRect(find.byType(TravelDateDetails)).left));
    await _capture(tester, boundary, 'travel_calendar');
    await tester.tap(find.text('编辑记录'));
    await tester.tap(find.byTooltip('删除记录'));
    expect(editCalls, 1);
    expect(deleteCalls, 1);
    await tester
        .tap(find.byKey(const ValueKey('travel-calendar-day-2026-10-02')));
    await tester.pumpAndSettle();
    expect(selected, DateTime(2026, 10, 2));
    expect(find.text('2026年10月2日'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('travel-month-record-2026-10-15')));
    await tester.pumpAndSettle();
    expect(selected, DateTime(2026, 10, 15));
    await tester.tap(find.byTooltip('上个月'));
    await tester.tap(find.byTooltip('下个月'));
    await tester.tap(find.text('2026年10月'));
    await tester.tap(find.text('今天'));
    expect(deltas, [-1, 1]);
    expect(monthPickerCalls, 1);
    expect(todayCalls, 1);
    expect(find.text('上一月记录'), findsNothing, reason: '月度列表不能混入其它月份');
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('$brightness 壁纸主题的大字月历和小窗口保持可用', (tester) async {
      final boundary = GlobalKey();
      var editCalls = 0;
      final calendar = _calendar(
          selectedDate: DateTime(2026, 10, 5),
          onSelectDate: (_) {},
          onEdit: () => editCalls++);
      await _pump(tester, calendar,
          brightness: brightness,
          wallpaper: true,
          textScaler: TextScaler.linear(1.8));
      expect(tester.takeException(), isNull);
      await _pump(tester, calendar,
          size: const Size(800, 650),
          brightness: brightness,
          wallpaper: true,
          boundaryKey: boundary);
      expect(tester.takeException(), isNull);
      await _capture(
          tester, boundary, 'travel_calendar_${brightness.name}_narrow');
      await _pump(tester, calendar,
          size: const Size(800, 650),
          brightness: brightness,
          wallpaper: true,
          textScaler: TextScaler.linear(1.8));
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('编辑记录'), 200,
          scrollable: find
              .descendant(
                of: find.byType(TravelDesktopCalendar),
                matching: find.byType(Scrollable),
              )
              .first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('编辑记录'));
      await tester.pumpAndSettle();
      expect(find.text('编辑记录').hitTestable(), findsOneWidget);
      await tester.tap(find.text('编辑记录'));
      await tester.pumpAndSettle();
      expect(editCalls, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('空日期详情仍能新增，小窗口大字和长内容可阅读', (tester) async {
    var additions = 0;
    await _pump(
        tester,
        TravelDateDetails(
            date: DateTime(2026, 10, 1),
            record: null,
            onAdd: () => additions++,
            onEdit: () {},
            onDelete: () {}),
        size: const Size(360, 640),
        textScaler: TextScaler.linear(1.8));
    await tester.tap(find.text('新增当天记录'));
    expect(additions, 1);
    expect(tester.takeException(), isNull);
    await _pump(
        tester,
        SingleChildScrollView(
            child: TravelDateDetails(
          date: _records[2].date,
          record: _records[2],
          onAdd: () {},
          onEdit: () {},
          onDelete: () {},
        )),
        size: const Size(360, 640),
        textScaler: TextScaler.linear(1.8));
    expect(find.text(_records[2].event), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
