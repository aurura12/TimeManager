import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/wake_up_document.dart';
import 'package:time_manager/models/wake_up_record.dart';
import 'package:time_manager/providers/wake_up_provider.dart';
import 'package:time_manager/screens/wake_up_history_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/wake_up_local_store.dart';
import 'package:time_manager/services/wake_up_sync_dependencies.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/main_tab_activity.dart';
import 'package:time_manager/widgets/wake_up_card.dart';

void main() {
  late DateTime now;
  late WakeUpProvider provider;

  setUp(() {
    now = DateTime(2026, 10, 4, 9, 45);
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
  });
  tearDown(AppIdentityService.resetForTesting);

  Future<void> prepare(WidgetTester tester,
      {WakeUpSyncDependencies? syncDependencies}) async {
    await AppIdentityService.load();
    provider = WakeUpProvider(
        clock: () => now, syncDependencies: syncDependencies, autoSync: false);
    await provider.ready;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      provider.dispose();
    });
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> mount(WidgetTester tester,
      {ThemeData? theme, bool isActive = true, double textScale = 1}) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: theme ?? AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: MainTabActivity(
              isActive: isActive,
              child: const ListViewWithWakeUpCard(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  LineChartData chartData(WidgetTester tester) =>
      tester.widget<LineChart>(find.byType(LineChart)).data;

  testWidgets('一键记录当前时间，分钟刷新并从保存的时间计算时长', (tester) async {
    await prepare(tester);
    await mount(tester);
    expect(find.text('今天还未记录起床时间'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wake-up-now')));
    await tester.pumpAndSettle();
    expect(find.text('09:45'), findsOneWidget);
    expect(find.text('不足 1 分钟'), findsOneWidget);
    expect(find.text('我起床了'), findsNothing);
    now = DateTime(2026, 10, 4, 12, 5);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('2 小时 20 分钟'), findsOneWidget);
    final restored = WakeUpProvider(clock: () => now);
    await restored.ready;
    expect(restored.recordFor(now)!.timeLabel, '09:45');
    restored.dispose();
  });

  testWidgets('显示待同步和失败状态，页面重试拉取另一端的新起床时间', (tester) async {
    var failPull = true;
    final remoteRecord = WakeUpRecord(DateTime(2026, 10, 4, 7, 20),
        updatedAt: now.millisecondsSinceEpoch + 1);
    final remote =
        WakeUpDocument(records: {remoteRecord.dateKey: remoteRecord});
    await prepare(tester,
        syncDependencies: WakeUpSyncDependencies(
          loadToken: () async => 'test-token',
          pull: ({required token, required userCode}) async => (
            success: !failPull,
            notFound: false,
            content: failPull ? null : remote.encode(),
            sha: failPull ? null : 'remote-sha',
            error: failPull ? 'offline' : null,
          ),
          push: (
                  {required token,
                  required userCode,
                  required content,
                  required commitMessage,
                  String? expectedSha,
                  bool expectNotFound = false}) async =>
              (success: true, conflict: false, error: null),
        ));
    await provider.record(DateTime(2026, 10, 4, 8), expectedKind: DiaryKind.j);
    await mount(tester);
    expect(find.text('等待同步到 Gitee'), findsOneWidget);
    await provider.synchronize();
    await tester.pumpAndSettle();
    expect(find.text('起床记录同步失败，可重试'), findsOneWidget);
    failPull = false;
    await tester.tap(find.byKey(const ValueKey('wake-up-sync-retry')));
    await tester.pumpAndSettle();
    expect(find.text('已同步到 Gitee'), findsOneWidget);
    expect(find.text('07:20'), findsOneWidget);
    expect(find.text('2 小时 25 分钟'), findsOneWidget);
    expect(find.byKey(const ValueKey('wake-up-sync-retry')), findsNothing);
    expect(provider.hasPendingSync, isFalse);
  });

  testWidgets('补填和修改使用滚轮，取消不保存，未来时间不写入', (tester) async {
    await prepare(tester);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('wake-up-edit')));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const ValueKey('time-wheel-hour')), const Offset(0, 44));
    await tester.pumpAndSettle();
    expect(find.text('08:45'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(provider.recordFor(now), isNull);
    await tester.tap(find.byKey(const ValueKey('wake-up-edit')));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const ValueKey('time-wheel-hour')), const Offset(0, -44));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('起床时间不能晚于当前时间'), findsOneWidget);
    expect(provider.recordFor(now), isNull);
    await tester.tap(find.byKey(const ValueKey('wake-up-edit')));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const ValueKey('time-wheel-hour')), const Offset(0, 44));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('08:45'), findsOneWidget);
    expect(find.text('1 小时 0 分钟'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wake-up-edit')));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const ValueKey('time-wheel-minute')), const Offset(0, 44));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(provider.recordFor(now)!.timeLabel, '08:44');
  });

  testWidgets('最近七天可补填，删除需要确认并立即更新平均值', (tester) async {
    await prepare(tester);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('wake-up-history-toggle')));
    await tester.pumpAndSettle();
    final yesterday = find.byKey(const ValueKey('wake-up-history-2026-10-03'));
    await tester.ensureVisible(yesterday);
    await tester.tap(yesterday);
    await tester.pumpAndSettle();
    expect(find.text('10月3日起床时间'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(provider.recordFor(DateTime(2026, 10, 3))!.timeLabel, '07:00');
    expect(find.text('平均 07:00 · 已记录 1 天'), findsOneWidget);
    final delete = find.byTooltip('删除10月3日起床记录');
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(provider.recordFor(DateTime(2026, 10, 3)), isNotNull);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(provider.recordFor(DateTime(2026, 10, 3)), isNull);
    expect(find.text('尚无起床记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('查看更多打开历史统计，包含七天以前的记录并可返回', (tester) async {
    await prepare(tester);
    await provider.record(DateTime(2026, 9, 15, 7, 30),
        expectedKind: DiaryKind.j);
    await mount(tester);
    expect(find.text('尚无起床记录'), findsOneWidget);
    final more = find.byKey(const ValueKey('wake-up-history-more'));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byType(WakeUpHistoryScreen), findsOneWidget);
    expect(find.text('已记录 1 天'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('wake-up-record-2026-09-15')), 150,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('wake-up-history-scroll')),
            matching: find.byType(Scrollable)));
    expect(find.text('2026年9月15日'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(WakeUpHistoryScreen), findsNothing);
    expect(find.text('尚无起床记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('跨天显示今天未记录，昨天的起床时间仍保留', (tester) async {
    await prepare(tester);
    await provider.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    await mount(tester);
    now = DateTime(2026, 10, 5, 0, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('今天还未记录起床时间'), findsOneWidget);
    expect(find.text('我起床了'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wake-up-history-toggle')));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('wake-up-history-2026-10-04')),
            matching: find.text('07:00')),
        findsOneWidget);
    expect(provider.recordFor(DateTime(2026, 10, 4)), isNotNull);
  });

  testWidgets('曲线按七个自然日排列，空缺断开且补填、删除后立即更新', (tester) async {
    await prepare(tester);
    for (final time in [
      DateTime(2026, 9, 27, 8), // 七天窗口外的记录不画入曲线。
      DateTime(2026, 9, 28, 6, 40),
      DateTime(2026, 9, 29, 7, 10),
      DateTime(2026, 10, 1, 8, 5),
      DateTime(2026, 10, 4, 9, 30),
    ]) {
      await provider.record(time, expectedKind: DiaryKind.j);
    }
    await mount(tester);
    final data = chartData(tester);
    expect(data.lineBarsData.single.spots, [
      const FlSpot(0, 400),
      const FlSpot(1, 430),
      FlSpot.nullSpot,
      const FlSpot(3, 485),
      FlSpot.nullSpot,
      FlSpot.nullSpot,
      const FlSpot(6, 570),
    ]);
    expect(
        tester
            .widget<Semantics>(find.byKey(const ValueKey('wake-up-chart')))
            .properties
            .value,
        '9月28日 06:40，9月29日 07:10，9月30日 未记录，10月1日 08:05，'
        '10月2日 未记录，10月3日 未记录，10月4日 09:30');
    final tooltip = data.lineTouchData.touchTooltipData.getTooltipItems([
      LineBarSpot(data.lineBarsData.single, 0, const FlSpot(3, 485)),
    ]);
    expect(tooltip.single!.text, '10月1日\n08:05');

    await provider.record(DateTime(2026, 9, 30, 7, 25),
        expectedKind: DiaryKind.j);
    await tester.pumpAndSettle();
    expect(
        chartData(tester).lineBarsData.single.spots[2], const FlSpot(2, 445));
    await provider.remove(DateTime(2026, 9, 29), expectedKind: DiaryKind.j);
    await tester.pumpAndSettle();
    expect(chartData(tester).lineBarsData.single.spots[1], FlSpot.nullSpot);
  });

  testWidgets('曲线容纳凌晨和深夜记录，切换身份后清空旧曲线', (tester) async {
    await prepare(tester);
    await mount(tester);
    expect(chartData(tester).lineBarsData, isEmpty);
    expect(find.text('记录后即可查看起床趋势'), findsOneWidget);

    await provider.record(DateTime(2026, 10, 3, 23, 59),
        expectedKind: DiaryKind.j);
    await provider.record(DateTime(2026, 10, 4, 0, 1),
        expectedKind: DiaryKind.j);
    await tester.pumpAndSettle();
    final data = chartData(tester);
    expect(data.minY, 0);
    expect(data.maxY, 1440);
    expect(data.lineBarsData.single.spots[5], const FlSpot(5, 1439));
    expect(data.lineBarsData.single.spots[6], const FlSpot(6, 1));
    expect(tester.takeException(), isNull);

    AppIdentityService.adoptManualKind(DiaryKind.g);
    await provider.reload();
    await tester.pumpAndSettle();
    expect(chartData(tester).lineBarsData, isEmpty);
    expect(find.text('记录后即可查看起床趋势'), findsOneWidget);
  });

  testWidgets('宽屏曲线在记录右侧，缩窄后放到记录下方', (tester) async {
    await prepare(tester);
    tester.view.physicalSize = const Size(1100, 700);
    await mount(tester);
    final details = find.byKey(const ValueKey('wake-up-today'));
    final chart = find.byKey(const ValueKey('wake-up-chart'));
    expect(tester.getTopLeft(chart).dx,
        greaterThan(tester.getTopRight(details).dx));
    expect(tester.getTopLeft(chart).dy, tester.getTopLeft(details).dy);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(chart).dy,
        greaterThan(tester.getBottomLeft(details).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏目标页和切后台暂停刷新，返回立即更新经过时长', (tester) async {
    await prepare(tester);
    await provider.record(DateTime(2026, 10, 4, 7), expectedKind: DiaryKind.j);
    await mount(tester, isActive: false);
    expect(find.text('2 小时 45 分钟'), findsOneWidget);
    now = DateTime(2026, 10, 4, 10);
    await tester.pump(const Duration(minutes: 2));
    expect(find.text('2 小时 45 分钟'), findsOneWidget);
    await mount(tester);
    expect(find.text('3 小时 0 分钟'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    now = DateTime(2026, 10, 4, 11);
    await tester.pump(const Duration(minutes: 2));
    expect(find.text('3 小时 0 分钟'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('4 小时 0 分钟'), findsOneWidget);
  });

  testWidgets('打开时间选择器期间切换身份，旧编辑不能写入新身份', (tester) async {
    await prepare(tester);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('wake-up-edit')));
    await tester.pumpAndSettle();
    AppIdentityService.adoptManualKind(DiaryKind.g);
    await provider.reload();
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('身份已切换，请重新记录'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(WakeUpLocalStore.keyFor(DiaryKind.g)), isNull);
    expect(prefs.getString(WakeUpLocalStore.keyFor(DiaryKind.j)), isNull);
  });

  testWidgets('窄屏大字和浅深壁纸主题均无溢出', (tester) async {
    await prepare(tester);
    await provider.record(DateTime(2026, 10, 4, 0, 1),
        expectedKind: DiaryKind.j);
    for (final theme in [
      AppTheme.light(),
      AppTheme.dark(),
      AppTheme.light(backgroundEnabled: true, surfaceOpacity: 0.72),
      AppTheme.dark(backgroundEnabled: true, surfaceOpacity: 0.72),
    ]) {
      await mount(tester, theme: theme, textScale: 2);
      expect(tester.takeException(), isNull);
      final card =
          tester.widget<Container>(find.byKey(const ValueKey('wake-up-card')));
      final fill = (card.decoration as BoxDecoration).color!;
      expect(
          fill.a,
          closeTo(
              theme.extension<AppWallpaperTheme>()!.enabled ? 0.72 : 1, 0.001));
      final toggle = find.byKey(const ValueKey('wake-up-history-toggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('wake-up-history-2026-09-28')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}

class ListViewWithWakeUpCard extends StatelessWidget {
  const ListViewWithWakeUpCard({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: const [WakeUpCard()],
      );
}
