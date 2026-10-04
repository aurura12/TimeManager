import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/wake_up_provider.dart';
import 'package:time_manager/screens/wake_up_history_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/wake_up_card.dart';

void main() {
  final now = DateTime(2026, 10, 4, 9, 45);
  late WakeUpProvider provider;

  setUp(() async {
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    await AppIdentityService.load();
    provider = WakeUpProvider(clock: () => now, autoSync: false);
    await provider.ready;
  });

  tearDown(() {
    provider.dispose();
    AppIdentityService.resetForTesting();
  });

  Future<void> seedRecords() async {
    for (final time in [
      DateTime(2025, 12, 31, 5),
      DateTime(2026, 7, 6, 9, 30), // 最近 90 天之外。
      DateTime(2026, 7, 7, 6, 30), // 最近 90 天的首日。
      DateTime(2026, 9, 4, 8), // 最近 30 天之外。
      DateTime(2026, 9, 5, 6, 50), // 最近 30 天的首日。
      DateTime(2026, 10, 4, 7, 10),
    ]) {
      await provider.record(time, expectedKind: DiaryKind.j);
    }
  }

  Future<void> mount(WidgetTester tester,
      {ThemeData? theme, double textScale = 1, bool showCard = false}) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? AppTheme.light(),
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      // Provider 只在首页路由内时，历史入口也必须复用同一个实例。
      home: ChangeNotifierProvider.value(
        value: provider,
        child: showCard
            ? Scaffold(body: ListView(children: const [WakeUpCard()]))
            : const WakeUpHistoryScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  LineChartData chartData(WidgetTester tester) =>
      tester.widget<LineChart>(find.byType(LineChart)).data;

  Finder statistic(String text) => find.descendant(
      of: find.byKey(const ValueKey('wake-up-history-metrics')),
      matching: find.text(text));

  Future<void> pickRange(
      WidgetTester tester, DateTime start, DateTime end) async {
    await tester.tap(find.widgetWithText(ChoiceChip, '自选日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final localizations = MaterialLocalizations.of(
        tester.element(find.byType(DateRangePickerDialog)));
    await tester.enterText(
        find.byType(TextField).at(0), localizations.formatCompactDate(start));
    await tester.enterText(
        find.byType(TextField).at(1), localizations.formatCompactDate(end));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
  }

  testWidgets('最近30天和90天包含首尾日期，全部记录跨年且明细倒序', (tester) async {
    await seedRecords();
    await mount(tester);
    expect(find.text('已记录 2 天'), findsOneWidget);
    expect(statistic('07:00'), findsOneWidget);
    expect(statistic('06:50'), findsOneWidget);
    expect(statistic('07:10'), findsOneWidget);
    expect(chartData(tester).maxX, 29);
    expect(chartData(tester).lineBarsData.single.spots.first,
        const FlSpot(0, 410));
    expect(chartData(tester).lineBarsData.single.spots[1], FlSpot.nullSpot);
    expect(chartData(tester).lineBarsData.single.spots.last,
        const FlSpot(29, 430));

    await tester.tap(find.text('最近 90 天'));
    await tester.pumpAndSettle();
    expect(find.text('已记录 4 天'), findsOneWidget);
    expect(statistic('07:08'), findsOneWidget);
    expect(statistic('06:30'), findsOneWidget);
    expect(statistic('08:00'), findsOneWidget);
    expect(chartData(tester).maxX, 89);
    expect(chartData(tester).lineBarsData.single.spots.first,
        const FlSpot(0, 390));

    await tester.tap(find.text('全部记录'));
    await tester.pumpAndSettle();
    expect(find.text('已记录 6 天'), findsOneWidget);
    expect(statistic('07:10'), findsOneWidget);
    expect(find.text('2025年12月31日 — 2026年10月4日'), findsOneWidget);
    final data = chartData(tester);
    final tooltip = data.lineTouchData.touchTooltipData.getTooltipItems([
      LineBarSpot(data.lineBarsData.single, 0, const FlSpot(0, 300)),
    ]);
    expect(tooltip.single!.text, '2025年12月31日\n05:00');

    final scrollable = find.descendant(
        of: find.byKey(const ValueKey('wake-up-history-scroll')),
        matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('wake-up-record-2026-07-06')), 150,
        scrollable: scrollable);
    expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('wake-up-record-2026-07-07')))
            .dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('wake-up-record-2026-07-06')))
            .dy));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('wake-up-record-2025-12-31')), 150,
        scrollable: scrollable);
    expect(find.text('2025年12月31日'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自选日期含首尾，取消保留原范围，修改后立即更新统计', (tester) async {
    await seedRecords();
    await mount(tester);
    await tester.tap(find.text('自选日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('已记录 2 天'), findsOneWidget);
    expect(find.text('2026年9月5日 — 2026年10月4日'), findsOneWidget);

    await pickRange(tester, DateTime(2026, 9, 4), DateTime(2026, 9, 5));
    expect(find.text('2026年9月4日 — 2026年9月5日'), findsOneWidget);
    expect(find.text('已记录 2 天'), findsOneWidget);
    expect(statistic('07:25'), findsOneWidget);
    expect(chartData(tester).lineBarsData.single.spots,
        [const FlSpot(0, 480), const FlSpot(1, 410)]);
    await provider.record(DateTime(2026, 9, 5, 6, 30),
        expectedKind: DiaryKind.j);
    await tester.pumpAndSettle();
    expect(statistic('07:15'), findsOneWidget);
    expect(
        chartData(tester).lineBarsData.single.spots.last, const FlSpot(1, 390));
    expect(tester.takeException(), isNull);
  });

  testWidgets('自选单日和无记录时段的曲线正常，空缺日期不按零点计算', (tester) async {
    await seedRecords();
    await mount(tester);
    await pickRange(tester, DateTime(2026, 9, 5), DateTime(2026, 9, 5));
    expect(find.text('已记录 1 天'), findsOneWidget);
    expect(chartData(tester).lineBarsData.single.spots, [const FlSpot(0, 410)]);
    expect(tester.takeException(), isNull);
    await pickRange(tester, DateTime(2026, 9, 6), DateTime(2026, 9, 7));
    expect(find.text('已记录 0 天'), findsOneWidget);
    expect(statistic('—'), findsNWidgets(3));
    expect(chartData(tester).lineBarsData, isEmpty);
    await tester.ensureVisible(find.text('所选时段暂无起床记录'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换身份清空旧历史，当前身份的新记录显示在全部记录中', (tester) async {
    await seedRecords();
    await mount(tester);
    await tester.tap(find.text('全部记录'));
    await tester.pumpAndSettle();
    AppIdentityService.adoptManualKind(DiaryKind.g);
    await provider.reload();
    await tester.pumpAndSettle();
    expect(find.text('已记录 0 天'), findsOneWidget);
    expect(chartData(tester).lineBarsData, isEmpty);
    expect(find.text('2025年12月31日'), findsNothing);
    await provider.record(DateTime(2026, 10, 4, 8, 30),
        expectedKind: DiaryKind.g);
    await tester.pumpAndSettle();
    expect(find.text('已记录 1 天'), findsOneWidget);
    expect(chartData(tester).lineBarsData.single.spots, [const FlSpot(0, 510)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页路由内的Provider可以通过入口带到历史页', (tester) async {
    await seedRecords();
    await mount(tester, showCard: true);
    final more = find.byKey(const ValueKey('wake-up-history-more'));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byType(WakeUpHistoryScreen), findsOneWidget);
    expect(find.text('已记录 2 天'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史页适配窄屏大字、浅深壁纸主题和桌面宽屏', (tester) async {
    await seedRecords();
    for (final theme in [
      AppTheme.light(),
      AppTheme.dark(),
      AppTheme.light(backgroundEnabled: true, surfaceOpacity: 0.72),
      AppTheme.dark(backgroundEnabled: true, surfaceOpacity: 0.72),
    ]) {
      await mount(tester, theme: theme, textScale: 2);
      await tester.tap(find.text('全部记录'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final card = tester.widget<Container>(
          find.byKey(const ValueKey('wake-up-history-statistics')));
      expect(
          (card.decoration as BoxDecoration).color!.a,
          closeTo(
              theme.extension<AppWallpaperTheme>()!.enabled ? 0.72 : 1, 0.001));
      tester.view.physicalSize = const Size(1100, 700);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
