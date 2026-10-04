import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/add_target_screen.dart';
import 'package:time_manager/screens/target_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/target_sync_dependencies.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/utils/platform_features.dart';
import 'package:time_manager/widgets/desktop_target_card.dart';
import 'package:time_manager/widgets/wake_up_card.dart';

final _exercise = Category(
  id: 'exercise',
  name: '运动',
  color: AppSemanticColors.palette[0],
  subCategories: const ['跑步', '散步'],
  updatedAt: 1,
);

List<Target> _targets() => [
      Target(
          id: 'duration',
          name: '运动',
          categoryId: _exercise.id,
          type: TargetType.duration,
          color: _exercise.color,
          period: '每周',
          durationHours: 6,
          updatedAt: 1),
      Target(
          id: 'frequency',
          name: '阅读',
          categoryId: 'reading',
          type: TargetType.frequency,
          color: AppSemanticColors.palette[1],
          period: '每天',
          frequencyCount: 3,
          updatedAt: 1),
      Target(
          id: 'cap',
          name: '娱乐',
          categoryId: 'entertainment',
          type: TargetType.duration,
          color: AppSemanticColors.palette[2],
          period: '今天',
          compareType: '少于',
          durationHours: 0.5,
          updatedAt: 1),
      Target(
          id: 'sleep',
          name: '睡觉',
          categoryId: 'sleeping',
          type: TargetType.timePoint,
          color: AppSemanticColors.palette[3],
          period: '每天',
          compareType: '少于',
          targetTime: '22:00',
          startTime: '16:00',
          endTime: '24:00',
          updatedAt: 1),
    ];

Future<TimeProvider> _provider(
  WidgetTester tester, {
  List<Target>? targets,
  bool saveSucceeds = true,
}) async {
  final categories = [
    _exercise,
    Category(
        id: 'reading',
        name: '阅读',
        color: AppSemanticColors.palette[1],
        updatedAt: 1),
    Category(
        id: 'entertainment',
        name: '娱乐',
        color: AppSemanticColors.palette[2],
        updatedAt: 1),
    Category(
        id: 'sleeping',
        name: '睡觉',
        color: AppSemanticColors.palette[3],
        updatedAt: 1),
  ];
  SharedPreferences.setMockInitialValues({
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'j',
    'identity_j_categories':
        categories.map((category) => jsonEncode(category.toJson())).toList(),
    'identity_j_targets': (targets ?? _targets())
        .map((target) => jsonEncode(target.toJson()))
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
    saveDataOverride: () async => saveSucceeds,
    targetSyncDependencies: TargetSyncDependencies.disabled(),
    scheduleSyncDependencies: ScheduleSyncDependencies(
      loadToken: () async => null,
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.error('offline'),
      pullDay: ({required token, required dateKey, required userCode}) async =>
          ScheduleGiteePullResult.error('offline'),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  await tester.runAsync(provider.waitForSyncReady);
  expect(provider.isInitialLoadFinished, isTrue);
  return provider;
}

Future<void> _pump(
  WidgetTester tester,
  TimeProvider provider, {
  Size size = const Size(1200, 820),
  ThemeData? theme,
  GlobalKey? boundaryKey,
  Widget screen = const TargetScreen(),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  const previewFont = String.fromEnvironment('TARGET_UI_PREVIEW_FONT');
  final baseTheme = theme ?? AppTheme.light();
  final appTheme = previewFont.isEmpty
      ? baseTheme
      : baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'TargetPreview'),
          primaryTextTheme:
              baseTheme.primaryTextTheme.apply(fontFamily: 'TargetPreview'),
          appBarTheme: baseTheme.appBarTheme.copyWith(
            titleTextStyle: (baseTheme.appBarTheme.titleTextStyle ??
                    AppText.pageTitle
                        .copyWith(color: baseTheme.colorScheme.onSurface))
                .copyWith(fontFamily: 'TargetPreview'),
          ),
          filledButtonTheme: FilledButtonThemeData(
              style: baseTheme.filledButtonTheme.style?.copyWith(
                  textStyle: WidgetStatePropertyAll(
                      AppText.button.copyWith(fontFamily: 'TargetPreview')))),
          outlinedButtonTheme: OutlinedButtonThemeData(
              style: baseTheme.outlinedButtonTheme.style?.copyWith(
                  textStyle: WidgetStatePropertyAll(
                      AppText.button.copyWith(fontFamily: 'TargetPreview')))),
          textButtonTheme: TextButtonThemeData(
              style: baseTheme.textButtonTheme.style?.copyWith(
                  textStyle: WidgetStatePropertyAll(
                      AppText.button.copyWith(fontFamily: 'TargetPreview')))),
        );
  await tester.pumpWidget(
    ChangeNotifierProvider<TimeProvider>(
      create: (_) => provider,
      child: RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
            debugShowCheckedModeBanner: false, theme: appTheme, home: screen),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String key, String label) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const previewDirectory = String.fromEnvironment('TARGET_UI_PREVIEW_DIR');
  if (previewDirectory.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(previewDirectory).create(recursive: true);
    await File('$previewDirectory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const previewFont = String.fromEnvironment('TARGET_UI_PREVIEW_FONT');
    if (previewFont.isNotEmpty) {
      final loader = FontLoader('TargetPreview');
      loader.addFont(File(previewFont)
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  testWidgets('目标页没有目标时也能记录起床时间', (tester) async {
    final provider = await _provider(tester, targets: []);
    final boundaryKey = GlobalKey();
    await _pump(tester, provider,
        size: const Size(360, 640), boundaryKey: boundaryKey);
    expect(find.byType(WakeUpCard), findsOneWidget);
    expect(find.text('我起床了'), findsOneWidget);
    await _capture(tester, boundaryKey, 'wake_up_empty');
    await tester.tap(find.byKey(const ValueKey('wake-up-now')));
    await tester.pumpAndSettle();
    expect(find.text('今天起床'), findsOneWidget);
    expect(find.text('已起床'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await _capture(tester, boundaryKey, 'wake_up_recorded');
    await tester.tap(find.byKey(const ValueKey('wake-up-history-toggle')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, boundaryKey, 'wake_up_history');
  });

  testWidgets('桌面编辑原地打开，校验输入并用快捷键保存', (tester) async {
    final provider = await _provider(tester);
    await _pump(tester, provider);
    expect(find.byType(Slidable), findsNothing);
    await tester.tap(find.byTooltip('编辑目标').first);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('target_duration')), 'NaN');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入大于 0 的时长'), findsOneWidget);
    expect(provider.targetById('duration')!.durationHours, 6);
    await tester.enterText(
        find.byKey(const ValueKey('target_duration')), '7.5');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(provider.targetById('duration')!.durationHours, 7.5);
    expect(provider.hasPendingTargetsGiteeUpload, isTrue);
  }, skip: !isDesktopPlatform);

  testWidgets('桌面自定义周期与目标时长独立保存', (tester) async {
    final provider = await _provider(tester);
    await _pump(tester, provider);
    await tester.tap(find.byTooltip('编辑目标').first);
    await tester.pumpAndSettle();
    await _select(tester, 'target_period', '每 N 天');
    await tester.enterText(
        find.byKey(const ValueKey('target_period_days')), '9');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(provider.targetById('duration')!.period, '每9天');
    expect(provider.targetById('duration')!.durationHours, 6);
  }, skip: !isDesktopPlatform);

  testWidgets('新建次数目标保留子事件关联并拒绝小数次数', (tester) async {
    final provider = await _provider(tester);
    await _pump(tester, provider);
    await tester.tap(find.text('新建目标'));
    await tester.pumpAndSettle();
    await _select(tester, 'target_event', '运动 / 跑步');
    await _select(tester, 'target_type', '次数目标');
    await tester.enterText(
        find.byKey(const ValueKey('target_frequency')), '2.5');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入正整数次数'), findsOneWidget);
    expect(provider.targets.length, 4);
    await tester.enterText(find.byKey(const ValueKey('target_frequency')), '4');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    final saved = provider.targets.singleWhere((target) => target.name == '跑步');
    expect(saved.categoryId, _exercise.id);
    expect(saved.type, TargetType.frequency);
    expect(saved.frequencyCount, 4);
    expect(provider.hasPendingTargetsGiteeUpload, isTrue);
  }, skip: !isDesktopPlatform);

  testWidgets('桌面时间点使用之前之后并保留24点结束边界', (tester) async {
    final provider = await _provider(tester, targets: [_targets().last]);
    await _pump(tester, provider);
    await tester.tap(find.byTooltip('编辑目标'));
    await tester.pumpAndSettle();
    expect(find.text('之前'), findsOneWidget);
    await _select(tester, 'target_comparison', '之后');
    await tester.enterText(find.byKey(const ValueKey('目标时间')), '25:00');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效时间（HH:mm）'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('目标时间')), '23:00');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = provider.targetById('sleep')!;
    expect(saved.compareType, '之后');
    expect(saved.targetTime, '23:00');
    expect(saved.endTime, '24:00');
  }, skip: !isDesktopPlatform);

  testWidgets('桌面保存失败保留表单和输入，Esc取消不修改目标', (tester) async {
    final provider = await _provider(tester, saveSucceeds: false);
    await _pump(tester, provider);
    await tester.tap(find.byTooltip('编辑目标').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('target_duration')), '8');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请稍后重试'), findsOneWidget);
    expect(provider.targetById('duration')!.durationHours, 6);
    await tester.tap(find.byKey(const ValueKey('target_duration')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(provider.targetById('duration')!.durationHours, 6);
  }, skip: !isDesktopPlatform);

  testWidgets('右键菜单可删除目标，取消确认不改变数据', (tester) async {
    final provider = await _provider(tester);
    await _pump(tester, provider);
    final card = find.byKey(const ValueKey('duration'));
    await tester.tap(card, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除目标'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(provider.targetById('duration'), isNotNull);
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除目标'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(provider.targetById('duration'), isNull);
    expect(provider.targets.length, 3);
  }, skip: !isDesktopPlatform);

  testWidgets('明确的拖拽把手调整目标顺序', (tester) async {
    final provider =
        await _provider(tester, targets: _targets().take(2).toList());
    await _pump(tester, provider);
    final first = find.byKey(const ValueKey('duration'));
    final second = find.byKey(const ValueKey('frequency'));
    final offset = tester.getCenter(second) - tester.getCenter(first);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('拖动排序').first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();
    await gesture.moveBy(
        offset + Offset(0, tester.getSize(second).height + AppSpacing.lg - 10));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
        provider.targets.map((target) => target.id), ['frequency', 'duration']);
    expect(provider.hasPendingTargetsGiteeUpload, isTrue);
  }, skip: !isDesktopPlatform);

  testWidgets('上限目标显示用量和超限状态，时间点显示当天状态', (tester) async {
    final provider = await _provider(tester);
    await _pump(tester, provider);
    expect(find.text('未超限'), findsOneWidget);
    expect(find.text('已用 0 / 上限 0.5 小时'), findsOneWidget);
    final category = provider.categories
        .firstWhere((category) => category.id == 'entertainment');
    provider.assignCategoryToSlots({60, 61, 62, 63}, category);
    await tester.pumpAndSettle();
    expect(find.text('已超限'), findsOneWidget);
    expect(find.text('今日未记录'), findsOneWidget);
  }, skip: !isDesktopPlatform);

  testWidgets('手机编辑自定义天数不会覆盖原目标时长', (tester) async {
    final provider = await _provider(tester);
    await _pump(tester, provider,
        screen: Scaffold(body: Builder(builder: (context) {
      return TextButton(
        onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => AddTargetScreen(target: provider.targets.first),
        )),
        child: const Text('打开手机编辑'),
      );
    })));
    await tester.tap(find.text('打开手机编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每n天'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '9');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('确定')));
    await tester.pumpAndSettle();
    expect(find.text('运动超过6小时'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(provider.targetById('duration')!.period, '每9天');
    expect(provider.targetById('duration')!.durationHours, 6);
  });

  testWidgets('桌面窄窗口和浅深主题无溢出，壁纸填充遵守透明度契约', (tester) async {
    final provider = await _provider(tester);
    for (final variant in ['light', 'dark', 'wallpaper', 'narrow']) {
      final boundaryKey = GlobalKey();
      final theme = variant == 'dark'
          ? AppTheme.dark()
          : AppTheme.light(
              backgroundEnabled: variant == 'wallpaper', surfaceOpacity: 0.72);
      await _pump(tester, provider,
          size: variant == 'narrow'
              ? const Size(360, 640)
              : const Size(1200, 820),
          theme: theme,
          boundaryKey: boundaryKey);
      expect(tester.takeException(), isNull);
      if (variant == 'wallpaper') {
        final card = tester.widget<Card>(find.descendant(
            of: find.byType(DesktopTargetCard).first,
            matching: find.byType(Card)));
        expect(card.color!.a, closeTo(0.72, 0.001));
      }
      await _capture(tester, boundaryKey, 'targets_$variant');
      await tester.tap(find.byTooltip('编辑目标').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, boundaryKey, 'editor_$variant');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }
  }, skip: !isDesktopPlatform);
}
