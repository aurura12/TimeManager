import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/background_image_provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/widgets/profile_settings_drawer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  testWidgets('Android settings hide the overwrite pull entry', (tester) async {
    final provider = TimeProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
          ChangeNotifierProvider(create: (_) => BackgroundImageProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            drawer: ProfileSettingsDrawer(
              onChanged: () {},
              desktopPlatformOverride: false,
              androidPlatformOverride: true,
            ),
          ),
        ),
      ),
    );

    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffoldState.openDrawer();
    await tester.pump();

    expect(find.text('覆盖拉取日程'), findsNothing);
    expect(find.text('同步中心'), findsOneWidget);
  });

  /// 建一个已经选好「乖乖」身份的桌面 Provider，并等初始化完成
  /// （否则身份切换会被 _isScheduleIdentityReady 挡掉）。
  Future<TimeProvider> createIdentityProvider(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: DiaryKind.g.code,
    });
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
    final provider = TimeProvider(identityModePlatformOverride: false);
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!provider.isInitialLoadFinished &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    return provider;
  }

  Future<void> openDrawerWith(
    WidgetTester tester,
    TimeProvider provider, {
    required bool desktop,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
          ChangeNotifierProvider(create: (_) => BackgroundImageProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            drawer: ProfileSettingsDrawer(
              onChanged: () {},
              desktopPlatformOverride: desktop,
            ),
          ),
        ),
      ),
    );
    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffoldState.openDrawer();
    await tester.pumpAndSettle();
  }

  testWidgets('background image setting exposes the complete opaque sheet',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TimeProvider();
    addTearDown(provider.dispose);

    await openDrawerWith(tester, provider, desktop: true);
    await tester.tap(find.text('背景图片'));
    await tester.pumpAndSettle();

    expect(find.text('选择照片'), findsOneWidget);
    expect(find.text('启用背景'), findsOneWidget);
    expect(find.text('照片不透明度'), findsOneWidget);
    expect(find.text('界面不透明度'), findsOneWidget);
    expect(find.text('移除背景照片'), findsOneWidget);
    // 两个滑块：照片不透明度（0–1）与界面不透明度（minSurfaceOpacity–1）
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders, hasLength(2));
    expect(sliders.first.min, 0);
    expect(sliders.first.max, 1);
    expect(
      sliders.last.min,
      BackgroundImageProvider.minSurfaceOpacity,
    );
    expect(sliders.last.max, 1);
    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor!.a,
      1,
    );
  });

  testWidgets('theme color setting opens the preset and custom color sheet',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TimeProvider();
    addTearDown(provider.dispose);

    await openDrawerWith(tester, provider, desktop: true);
    await tester.tap(find.text('主题色'));
    await tester.pumpAndSettle();

    expect(find.text('橄榄绿'), findsWidgets);
    expect(find.text('天空蓝'), findsOneWidget);
    expect(find.text('自定义色值'), findsOneWidget);
    expect(find.text('调色板'), findsOneWidget);
    expect(find.byKey(const ValueKey('color-picker-plane')), findsOneWidget);
    expect(find.text('配色预览'), findsOneWidget);
    expect(find.text('应用主题色'), findsOneWidget);
  });

  testWidgets('desktop identity switch requires confirmation', (tester) async {
    final provider = await createIdentityProvider(tester);
    addTearDown(provider.dispose);
    expect(provider.scheduleUser, DiaryKind.g);

    await openDrawerWith(tester, provider, desktop: true);
    // 已选中身份时默认收起，先展开
    await tester.tap(find.text('Windows 用户身份'));
    await tester.pumpAndSettle();
    expect(find.text('晶晶'), findsOneWidget);

    // 点另一个身份 → 必须先确认
    await tester.tap(find.text('晶晶'));
    await tester.pumpAndSettle();
    expect(find.text('确认切换身份'), findsOneWidget);

    // 取消 → 身份不变，且身份列表仍在展开状态
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(provider.scheduleUser, DiaryKind.g);
    expect(find.text('晶晶'), findsOneWidget);

    // 再确认一次 → 真的切过去
    await tester.tap(find.text('晶晶'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(provider.scheduleUser, DiaryKind.j);
  });

  testWidgets('mobile identity switch also requires confirmation',
      (tester) async {
    // 移动端本地数据按身份分片、切换不会串数据，所以文案与桌面端不同，
    // 但同样要二次确认，避免误触换掉整份本地数据。
    final provider = await createIdentityProvider(tester);
    addTearDown(provider.dispose);

    await openDrawerWith(tester, provider, desktop: false);
    await tester.tap(find.text('手动用户身份'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('晶晶'));
    await tester.pumpAndSettle();
    expect(find.text('确认切换身份'), findsOneWidget);
    expect(find.textContaining('互不影响'), findsOneWidget);

    // 取消 → 身份不变
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(provider.scheduleUser, DiaryKind.g);

    // 确认 → 切过去
    await tester.tap(find.text('晶晶'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(provider.scheduleUser, DiaryKind.j);
  });

  testWidgets('first identity selection does not ask for confirmation',
      (tester) async {
    // 未选过身份时是前置条件，没有"切换"可言，不该打扰。
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
    });
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
    final provider = TimeProvider(identityModePlatformOverride: false);
    addTearDown(provider.dispose);
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!provider.isInitialLoadFinished &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(provider.hasSelectedScheduleUser, isFalse);

    await openDrawerWith(tester, provider, desktop: true);
    // 未选择时身份列表默认展开
    expect(find.text('晶晶'), findsOneWidget);
    await tester.tap(find.text('晶晶'));
    await tester.pumpAndSettle();

    expect(find.text('确认切换身份'), findsNothing);
    expect(provider.scheduleUser, DiaryKind.j);
  });

  testWidgets('desktop settings hide all manual schedule sync entries',
      (tester) async {
    final provider = TimeProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
          ChangeNotifierProvider(create: (_) => BackgroundImageProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            drawer: ProfileSettingsDrawer(
              onChanged: () {},
              desktopPlatformOverride: true,
            ),
          ),
        ),
      ),
    );

    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffoldState.openDrawer();
    await tester.pump();

    expect(find.text('拉取所有日程'), findsNothing);
    expect(find.text('推送所有日程'), findsNothing);
    expect(find.text('覆盖拉取日程'), findsNothing);
    expect(find.text('同步中心'), findsOneWidget);
    expect(find.text('Windows 用户身份'), findsOneWidget);
  });

  testWidgets(
    'mobile settings hides manual identity entry in Google mode',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        AppIdentityService.modeKey: 'google',
        AppIdentityService.legacySyncKey: true,
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );

      final provider = TimeProvider(
        identityModePlatformOverride: true,
        googleCalendarSyncPlatformOverride: true,
      );
      addTearDown(provider.dispose);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel(
            'plugins.it_nomads.com/flutter_secure_storage',
          ),
          null,
        );
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: provider),
            ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
            ChangeNotifierProvider(create: (_) => BackgroundImageProvider()),
          ],
          child: MaterialApp(
            home: Scaffold(
              drawer: ProfileSettingsDrawer(
                onChanged: () {},
                desktopPlatformOverride: false,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (!provider.isInitialLoadFinished &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();

      final scaffoldState = tester.state<ScaffoldState>(
        find.byType(Scaffold),
      );
      scaffoldState.openDrawer();
      await tester.pump();

      expect(find.text('手动用户身份'), findsNothing);
    },
  );
}
