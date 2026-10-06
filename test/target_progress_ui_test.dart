import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/models/target_progress.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/target_detail_screen.dart';
import 'package:time_manager/screens/target_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/target_progress_calculator.dart';
import 'package:time_manager/services/target_sync_dependencies.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/main_tab_activity.dart';
import 'package:time_manager/widgets/target_calendar_day.dart';
import 'package:time_manager/widgets/target_day_refresh.dart';

final _category = Category(
    id: 'study', name: '学习', color: AppSemanticColors.brand, updatedAt: 1);

Target _target(
        {String comparison = '至少', TargetType type = TargetType.duration}) =>
    Target(
        id: 'study-goal',
        name: '学习',
        categoryId: _category.id,
        color: _category.color,
        type: type,
        period: '每天',
        compareType: comparison,
        durationHours: 5,
        frequencyCount: 3,
        targetTime: '08:00',
        startTime: '06:00',
        endTime: '24:00');

TargetProgress _progress(Target target, double value, {DateTime? now}) =>
    TargetProgressCalculator.evaluate(
        target: target,
        period:
            TargetProgressCalculator.periodFor(target, DateTime(2026, 10, 6)),
        value: value,
        hasRecords: value > 0,
        now: now ?? DateTime(2026, 10, 6, 12));

Future<TimeProvider> _provider(WidgetTester tester, Target target,
    {List<Target> additionalTargets = const []}) async {
  SharedPreferences.setMockInitialValues({
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'j',
    'identity_j_categories': [jsonEncode(_category.toJson())],
    'identity_j_targets': [target, ...additionalTargets]
        .map((item) => jsonEncode(item.toJson()))
        .toList(),
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null);
  messenger.setMockMethodCallHandler(
      const MethodChannel('home_widget'), (call) async => null);
  final provider = TimeProvider(
    identityModePlatformOverride: true,
    googleCalendarSyncPlatformOverride: false,
    scheduleGiteeDebounce: const Duration(days: 1),
    localSaveDebounce: const Duration(days: 1),
    saveDataOverride: () async => true,
    targetSyncDependencies: TargetSyncDependencies.disabled(),
    scheduleSyncDependencies: ScheduleSyncDependencies(
      loadToken: () async => null,
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.error('offline'),
      pullDay: ({required token, required dateKey, required userCode}) async =>
          ScheduleGiteePullResult.error('offline'),
    ),
  );
  await tester.runAsync(provider.waitForSyncReady);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  return provider;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const directory = String.fromEnvironment('TARGET_UI_PREVIEW_DIR');
  if (directory.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const font = String.fromEnvironment('TARGET_UI_PREVIEW_FONT');
    if (font.isEmpty) return;
    final loader = FontLoader('TargetPreview');
    loader.addFont(File(font).readAsBytes().then(ByteData.sublistView));
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  testWidgets('日期格按面积从底部填充，只有达标才显示勾，语义包含数值', (tester) async {
    final semantics = tester.ensureSemantics();
    final target = _target();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
          body: Row(children: [
        for (final value in [0.0, 2.0, 5.0])
          SizedBox(
              width: 48,
              height: 48,
              child: TargetCalendarDay(
                key: ValueKey(value),
                date: DateTime(2026, 10, 6),
                progress: _progress(target, value),
                isToday: false,
                onTap: () {},
              )),
      ])),
    ));
    final empty = find.byKey(const ValueKey(0.0));
    final partial = find.byKey(const ValueKey(2.0));
    final full = find.byKey(const ValueKey(5.0));
    expect(find.descendant(of: empty, matching: find.byType(ClipRect)),
        findsNothing);
    final clip = tester.widget<ClipRect>(
        find.descendant(of: partial, matching: find.byType(ClipRect)));
    expect(clip.clipper!.getClip(const Size(40, 40)),
        const Rect.fromLTWH(0, 24, 40, 16));
    expect(find.descendant(of: partial, matching: find.byIcon(Icons.check)),
        findsNothing);
    expect(find.descendant(of: full, matching: find.byIcon(Icons.check)),
        findsWidgets);
    expect(tester.getSemantics(partial).label, contains('2 / 5 小时，未达目标'));
    semantics.dispose();
  });

  testWidgets('满格的严格超过和暂时等于没有勾，超限显示警告', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
          body: Row(children: [
        for (final comparison in ['超过', '等于', '少于'])
          SizedBox(
              width: 48,
              height: 48,
              child: TargetCalendarDay(
                key: ValueKey(comparison),
                date: DateTime(2026, 10, 6),
                progress: _progress(_target(comparison: comparison), 5),
                isToday: false,
                onTap: () {},
              )),
      ])),
    ));
    expect(find.byIcon(Icons.check), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('少于')),
            matching: find.byIcon(Icons.priority_high)),
        findsWidgets);
  });

  testWidgets('手机点击打开底部明细，电脑悬停与点击展示同一进度，日历星期对齐', (tester) async {
    final desktop =
        debugDefaultTargetPlatformOverride == TargetPlatform.windows;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(desktop ? 1100 : 360, 900);
    addTearDown(tester.view.reset);
    final target = _target();
    final provider = await _provider(tester, target);
    final today = TargetProgressCalculator.day(DateTime.now());
    provider.assignCategoryToSlots({for (var i = 0; i < 12; i++) i}, _category,
        date: today);
    final boundary = GlobalKey();
    const previewFont = String.fromEnvironment('TARGET_UI_PREVIEW_FONT');
    final baseTheme = AppTheme.light();
    final theme = previewFont.isEmpty
        ? baseTheme
        : baseTheme.copyWith(
            textTheme: baseTheme.textTheme.apply(fontFamily: 'TargetPreview'),
            primaryTextTheme:
                baseTheme.primaryTextTheme.apply(fontFamily: 'TargetPreview'),
            appBarTheme: baseTheme.appBarTheme.copyWith(
                titleTextStyle: baseTheme.appBarTheme.titleTextStyle!
                    .copyWith(fontFamily: 'TargetPreview')),
            textButtonTheme: TextButtonThemeData(
                style: baseTheme.textButtonTheme.style?.copyWith(
                    textStyle: WidgetStatePropertyAll(baseTheme
                        .textTheme.labelLarge!
                        .copyWith(fontFamily: 'TargetPreview')))),
          );
    await tester.pumpWidget(ChangeNotifierProvider<TimeProvider>(
      create: (_) => provider,
      child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: TargetDetailScreen(targetId: target.id),
          )),
    ));
    await tester.pumpAndSettle();
    final cell = find.byKey(
        ValueKey('target-day-${target.id}-${TargetProgress.dateLabel(today)}'));
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    final cellSize = tester.getSize(cell);
    expect(cellSize.width, greaterThanOrEqualTo(44));
    expect(cellSize.height, greaterThanOrEqualTo(48));
    final firstDate = DateTime(today.year, today.month, 1);
    final firstCell = find.byKey(ValueKey(
        'target-day-${target.id}-${TargetProgress.dateLabel(firstDate)}'));
    final month =
        find.ancestor(of: firstCell, matching: find.byType(Column)).first;
    final weekday = find
        .descendant(
            of: month,
            matching: find.text(
                ['一', '二', '三', '四', '五', '六', '日'][firstDate.weekday - 1]))
        .last;
    expect(tester.getCenter(firstCell).dx,
        closeTo(tester.getCenter(weekday).dx, 0.01));
    await _capture(
        tester, boundary, desktop ? 'calendar_desktop' : 'calendar_mobile');
    if (desktop) {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(cell));
      await tester.pumpAndSettle(const Duration(milliseconds: 600));
      expect(find.text('${TargetProgress.dateLabel(today)}，2 / 5 小时，未达目标'),
          findsOneWidget);
      await mouse.removePointer();
    }
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.text('2 / 5 小时'), findsWidgets);
    expect(find.byType(desktop ? AlertDialog : BottomSheet), findsOneWidget);
    await _capture(
        tester, boundary, desktop ? 'detail_desktop' : 'detail_mobile');
    provider.assignCategoryToSlots({for (var i = 12; i < 30; i++) i}, _category,
        date: today);
    await tester.pumpAndSettle();
    expect(find.text('5 / 5 小时'), findsWidgets);
    expect(find.text('已达目标'), findsWidgets);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: cell, matching: find.byIcon(Icons.check)),
        findsWidgets);
    expect(tester.takeException(), isNull);
  },
      variant: TargetPlatformVariant(
          {TargetPlatform.android, TargetPlatform.windows}));

  testWidgets('窄屏大字体和浅深色壁纸的目标详情无溢出，日期填充透明度一致', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    final target = _target();
    final provider = await _provider(tester, target);
    final today = TargetProgressCalculator.day(DateTime.now());
    provider.assignCategoryToSlots({for (var i = 0; i < 12; i++) i}, _category,
        date: today);
    for (final dark in [false, true]) {
      final theme = dark
          ? AppTheme.dark(backgroundEnabled: true, surfaceOpacity: .72)
          : AppTheme.light(backgroundEnabled: true, surfaceOpacity: .72);
      await tester.pumpWidget(ChangeNotifierProvider<TimeProvider>(
        create: (_) => provider,
        child: MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!),
          home: TargetDetailScreen(targetId: target.id),
        ),
      ));
      await tester.pumpAndSettle();
      final cell = find.byKey(ValueKey(
          'target-day-${target.id}-${TargetProgress.dateLabel(today)}'));
      await tester.ensureVisible(cell);
      await tester.pumpAndSettle();
      final fills = tester.widgetList<ColoredBox>(
          find.descendant(of: cell, matching: find.byType(ColoredBox)));
      expect(fills, isNotEmpty);
      for (final fill in fills) {
        expect(fill.color.a, closeTo(.72, .001));
      }
      expect(tester.takeException(), isNull);
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    }
  },
      variant: TargetPlatformVariant(
          {TargetPlatform.android, TargetPlatform.windows}));

  testWidgets('过午夜重算达标状态，后台与隐藏页暂停，返回立即更新', (tester) async {
    var clock = DateTime(2026, 10, 6, 23, 59, 59);
    var active = true;
    final target = _target(comparison: '等于');
    Widget page() => Directionality(
          textDirection: TextDirection.ltr,
          child: MainTabActivity(
            isActive: active,
            child: TargetDayRefresh(
              clock: () => clock,
              builder: (_) =>
                  Text(_progress(target, 5, now: clock).statusLabel),
            ),
          ),
        );
    await tester.pumpWidget(page());
    expect(find.text('暂时达标'), findsOneWidget);
    clock = DateTime(2026, 10, 7);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已达目标'), findsOneWidget);
    active = false;
    await tester.pumpWidget(page());
    clock = DateTime(2026, 10, 6, 12);
    await tester.pump(const Duration(days: 2));
    expect(find.text('已达目标'), findsOneWidget);
    active = true;
    await tester.pumpWidget(page());
    expect(find.text('暂时达标'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    clock = DateTime(2026, 10, 7);
    await tester.pump(const Duration(days: 2));
    expect(find.text('暂时达标'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('已达目标'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('手机和电脑卡片共用时长、次数和时间点状态，彩色卡片上的进度可辨认', (tester) async {
    final desktop =
        debugDefaultTargetPlatformOverride == TargetPlatform.windows;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(desktop ? 1100 : 360, 1200);
    addTearDown(tester.view.reset);
    final duration = _target();
    final frequency =
        duration.copyWith(id: 'frequency', type: TargetType.frequency);
    final point = duration.copyWith(
        id: 'point',
        type: TargetType.timePoint,
        compareType: '之后',
        startTime: '06:00',
        endTime: '10:00');
    final provider = await _provider(tester, duration,
        additionalTargets: [frequency, point]);
    provider.assignCategoryToSlots(
        {for (var i = 48; i < 60; i++) i, 72, 78}, _category);
    await tester.pumpWidget(ChangeNotifierProvider<TimeProvider>(
        create: (_) => provider,
        child:
            MaterialApp(theme: AppTheme.light(), home: const TargetScreen())));
    await tester.pumpAndSettle();
    expect(find.text(desktop ? '目标' : '我的计划'), findsOneWidget);
    expect(find.text('2.33 / 5 小时'), findsOneWidget);
    expect(find.text('3 / 3 次'), findsOneWidget);
    expect(find.text('今日准时'), findsOneWidget);
    if (!desktop) {
      for (final bar in tester.widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator))) {
        expect(AppSemanticColors.contrastRatio(bar.color!, _category.color),
            greaterThanOrEqualTo(3));
      }
    }
    expect(tester.takeException(), isNull);
  },
      variant: TargetPlatformVariant(
          {TargetPlatform.android, TargetPlatform.windows}));

  testWidgets('周目标显示当天记录与完整周期，区间外日期不显示周期已达标', (tester) async {
    final today = TargetProgressCalculator.day(DateTime.now());
    final target = _target().copyWith(period: '每周');
    final provider = await _provider(tester, target);
    provider.assignCategoryToSlots({for (var i = 0; i < 30; i++) i}, _category,
        date: today);
    await tester.pumpWidget(ChangeNotifierProvider<TimeProvider>(
        lazy: false,
        create: (_) => provider,
        child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => showTargetDayDetails(context, provider,
                            provider.targetById(target.id)!, today),
                        child: const Text('明细')))))));
    await tester.tap(find.text('明细'));
    await tester.pumpAndSettle();
    expect(find.text('当天记录：5 小时'), findsOneWidget);
    expect(find.text('5 / 5 小时'), findsOneWidget);
    expect(find.text('已达目标'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    final start = DateTime(today.year, today.month, today.day + 1);
    final end = DateTime(today.year, today.month, today.day + 3);
    await tester.runAsync(() => provider.updateTarget(target.copyWith(
        period:
            '${TargetProgress.dateLabel(start)}~${TargetProgress.dateLabel(end)}')));
    await tester.tap(find.text('明细'));
    await tester.pumpAndSettle();
    expect(find.text('不在目标日期内'), findsOneWidget);
    expect(find.text('已达目标'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });
}
