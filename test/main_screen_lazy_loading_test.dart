import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/main_tab_id.dart';
import 'package:time_manager/models/global_search_result.dart';
import 'package:time_manager/providers/main_tab_provider.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/providers/background_image_provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/check_in_screen.dart';
import 'package:time_manager/screens/diary_screen.dart';
import 'package:time_manager/screens/home_screen.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'package:time_manager/screens/global_search_screen.dart';
import 'package:time_manager/screens/add_target_screen.dart';
import 'package:time_manager/screens/desktop_shortcut_settings_screen.dart';
import 'package:time_manager/screens/desktop_layout_settings_screen.dart';
import 'package:time_manager/providers/desktop_shortcut_provider.dart';
import 'package:time_manager/utils/platform_features.dart';
import 'package:time_manager/screens/main_tab_settings_screen.dart';
import 'package:time_manager/screens/profile_screen.dart';
import 'package:time_manager/screens/target_screen.dart';
import 'package:time_manager/screens/travel_screen.dart';
import 'package:time_manager/services/on_this_day_service.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/theme/app_theme.dart';

class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    return null;
  }

  @override
  bool supportsAuthenticate() => false;

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) {
    throw UnimplementedError();
  }

  @override
  bool authorizationRequiresUserInteraction() => false;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<void> clearAuthorizationToken(
      ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

class _CountingProvider extends TimeProvider {
  _CountingProvider()
      : super(
          identityModePlatformOverride: false,
          googleCalendarSyncPlatformOverride: false,
          localSaveDebounce: const Duration(hours: 1),
          scheduleSyncDependencies: ScheduleSyncDependencies(
            loadToken: () async => null,
            listPaths: ({required token, required userCode}) async =>
                ScheduleGiteeListWithShaResult.error('offline'),
            pullDay: (
                    {required token,
                    required dateKey,
                    required userCode}) async =>
                ScheduleGiteePullResult.error('offline'),
          ),
        );

  int statsCalls = 0;
  int dailyCalls = 0;
  List<DailyStatistics>? lastDailyStatistics;

  @override
  Map<String, double> getStatistics(DateTime start, DateTime end) {
    statsCalls++;
    return super.getStatistics(start, end);
  }

  @override
  List<DailyStatistics> getDailyStatistics(DateTime start, DateTime end) {
    dailyCalls++;
    return lastDailyStatistics = super.getDailyStatistics(start, end);
  }

  void notifyStatusOnly() => notifyListeners();

  void resetCounters() {
    statsCalls = 0;
    dailyCalls = 0;
  }
}

void _installPluginMocks(Map<String, Object> initialPreferences) {
  SharedPreferences.setMockInitialValues({
    'on_this_day_last_shown_date': OnThisDayService.dateKeyOf(DateTime.now()),
    ...initialPreferences,
  });
  GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();

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
    (call) async => '/tmp/time_manager_lazy_loading_test',
  );
}

Future<TimeProvider> _pumpMainScreen(
  WidgetTester tester, {
  TimeProvider Function()? createProvider,
  Map<String, Object> initialPreferences = const {},
  Size screenSize = const Size(360, 800),
  ThemeData? theme,
}) async {
  _installPluginMocks(initialPreferences);
  tester.view.physicalSize = screenSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final provider = createProvider?.call() ?? TimeProvider();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<TimeProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => MainTabProvider()),
        ChangeNotifierProvider(create: (_) => DesktopShortcutProvider()),
        ChangeNotifierProvider(create: (_) => DesktopLayoutProvider()),
        ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
        ChangeNotifierProvider(create: (_) => BackgroundImageProvider()),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.light(),
        darkTheme: theme ?? AppTheme.dark(),
        home: const MainScreen(),
      ),
    ),
  );

  for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(provider.isInitialLoadFinished, isTrue);
  await tester.pump();
  return provider;
}

Finder _tab(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

void main() {
  Future<void> shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
    final modifier = Platform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  testWidgets('宽屏左侧导航沿用标签顺序，切布局和缩放保留页面与统计状态', (tester) async {
    await _pumpMainScreen(tester,
        createProvider: _CountingProvider.new,
        screenSize: const Size(1400, 900),
        initialPreferences: {
          DesktopLayoutProvider.storageKey:
              jsonEncode({'navigation': 'side', 'categoryWidth': 300}),
          MainTabProvider.storageKey: jsonEncode({
            'order': [
              'record',
              'profile',
              'diary',
              'target',
              'travel',
              'check_in'
            ],
            'hidden': ['travel', 'check_in'],
          }),
        });
    expect(find.byType(NavigationBar), findsNothing);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations.map((item) => (item.label as Text).data),
        ['记录', '我的', '日记', '目标']);
    final homeState = tester.state(find.byType(HomeScreen));
    await tester.tap(find.descendant(
        of: find.byType(NavigationRail), matching: find.text('我的')));
    await tester.pumpAndSettle();
    final profileState = tester.state(find.byType(ProfileScreen));
    final layout =
        tester.element(find.byType(MainScreen)).read<DesktopLayoutProvider>();
    await layout.setNavigationLayout(DesktopNavigationLayout.bottom);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ProfileScreen)), same(profileState));
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1);
    await layout.setNavigationLayout(DesktopNavigationLayout.side);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ProfileScreen)), same(profileState));
    tester.view.physicalSize = const Size(800, 700);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.state(find.byType(ProfileScreen)), same(profileState));
    await tester.tap(_tab('记录'));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(HomeScreen)), same(homeState));
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(tester.state(find.byType(HomeScreen)), same(homeState));
    expect(tester.takeException(), isNull);
  });

  testWidgets('左侧导航数字快捷键保持映射，桌面布局可从外观设置打开', (tester) async {
    if (!isDesktopPlatform) return;
    await _pumpMainScreen(tester,
        createProvider: _CountingProvider.new,
        screenSize: const Size(1400, 1100),
        initialPreferences: {
          DesktopLayoutProvider.storageKey: jsonEncode({'navigation': 'side'}),
        });
    await shortcut(tester, LogicalKeyboardKey.digit6);
    expect(find.byType(ProfileScreen), findsOneWidget);
    await shortcut(tester, LogicalKeyboardKey.comma);
    await tester.tap(find.text('外观设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('桌面布局'));
    await tester.tap(find.text('桌面布局'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopLayoutSettingsScreen), findsOneWidget);
    await tester.tap(find.text('底部导航（原有布局）'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数字快捷键遵循可见标签顺序，新建和搜索作用于当前模块', (tester) async {
    final provider = await _pumpMainScreen(
      tester,
      createProvider: _CountingProvider.new,
      initialPreferences: {
        MainTabProvider.storageKey: jsonEncode({
          'order': [
            'target',
            'record',
            'profile',
            'diary',
            'travel',
            'check_in'
          ],
          'hidden': ['diary', 'travel', 'check_in'],
        }),
      },
    );
    final targetElement = tester.element(find.byType(TargetScreen));
    await shortcut(tester, LogicalKeyboardKey.keyN);
    expect(find.byType(AddTargetScreen), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await shortcut(tester, LogicalKeyboardKey.keyF);
    expect(
        tester
            .widget<GlobalSearchScreen>(find.byType(GlobalSearchScreen))
            .initialContentType,
        GlobalSearchContentType.target);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await shortcut(tester, LogicalKeyboardKey.digit2);
    expect(find.byType(HomeScreen), findsOneWidget);
    final category =
        Category(id: 'shortcuts', name: '快捷键测试', color: AppTheme.seedColor);
    provider.assignCategoryToSlots({48}, category);
    await tester.pump();
    await shortcut(tester, LogicalKeyboardKey.digit1);
    expect(tester.element(find.byType(TargetScreen)), same(targetElement));
    await shortcut(tester, LogicalKeyboardKey.keyZ);
    expect(provider.slots[48].recorded, isTrue, reason: '目标页不能撤销记录页的编辑');
    await shortcut(tester, LogicalKeyboardKey.digit2);
    await shortcut(tester, LogicalKeyboardKey.keyZ);
    expect(provider.slots[48].recorded, isFalse);
    await shortcut(tester, LogicalKeyboardKey.digit3);
    expect(find.byType(ProfileScreen), findsOneWidget);
    await shortcut(tester, LogicalKeyboardKey.digit4);
    expect(find.byType(ProfileScreen), findsOneWidget, reason: '隐藏标签不占快捷键位置');
    expect(find.byType(DiaryScreen, skipOffstage: false), findsNothing);
    await tester.runAsync(provider.onAppBackgrounded);
  }, skip: !isDesktopPlatform);

  testWidgets('设置快捷键打开我的抽屉，帮助入口进入可编辑的快捷键设置', (tester) async {
    await _pumpMainScreen(tester, createProvider: _CountingProvider.new);
    await shortcut(tester, LogicalKeyboardKey.comma);
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.byType(Drawer), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    await shortcut(tester, LogicalKeyboardKey.digit1);
    await tester.tap(find.byTooltip('键盘快捷键'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopShortcutSettingsScreen), findsOneWidget);
  }, skip: !isDesktopPlatform);

  testWidgets('启动时只构造记录页，未访问 Tab 保持未构造', (tester) async {
    await _pumpMainScreen(tester);

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(DiaryScreen), findsNothing);
    expect(find.byType(TravelScreen), findsNothing);
    expect(find.byType(CheckInScreen), findsNothing);
    expect(find.byType(TargetScreen), findsNothing);
    expect(find.byType(ProfileScreen), findsNothing);

    expect(_tab('目标'), findsOneWidget);
  });

  testWidgets('首次访问 Tab 后页面在 IndexedStack 中保活', (tester) async {
    await _pumpMainScreen(tester);

    await tester.tap(_tab('日记'));
    await tester.pump();
    expect(find.byType(DiaryScreen), findsOneWidget);
    final diaryElement = tester.element(find.byType(DiaryScreen));

    await tester.tap(_tab('出行'));
    await tester.pump();
    expect(find.byType(TravelScreen), findsOneWidget);
    expect(find.byType(DiaryScreen, skipOffstage: false), findsOneWidget);
    expect(
      tester.element(find.byType(DiaryScreen, skipOffstage: false)),
      same(diaryElement),
    );

    await tester.tap(_tab('日记'));
    await tester.pump();
    expect(tester.element(find.byType(DiaryScreen)), same(diaryElement));

    await tester.tap(_tab('目标'));
    await tester.pump();
    expect(find.byType(TargetScreen), findsOneWidget);
    final targetElement = tester.element(find.byType(TargetScreen));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );

    await tester.tap(_tab('日记'));
    await tester.pump();
    expect(find.byType(TargetScreen), findsNothing);
    expect(
      tester.element(find.byType(TargetScreen, skipOffstage: false)),
      same(targetElement),
    );

    await tester.tap(_tab('目标'));
    await tester.pump();
    expect(tester.element(find.byType(TargetScreen)), same(targetElement));
  });

  testWidgets('最后一个 Tab 导航到我的页面', (tester) async {
    await _pumpMainScreen(tester);

    await tester.tap(_tab('我的'));
    await tester.pump();

    expect(find.byType(ProfileScreen), findsOneWidget);
    final navigationBar = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    expect(navigationBar.selectedIndex, 5);
    expect(_tab('我的'), findsOneWidget);
    expect(find.byTooltip('更多功能'), findsNothing);
  });

  for (final tab in MainTabId.values.where((tab) => tab != MainTabId.profile)) {
    testWidgets('更多功能打开隐藏的${tab.label}，两种返回方式均保留隐藏设置与页面状态', (tester) async {
      await _pumpMainScreen(
        tester,
        initialPreferences: {
          MainTabProvider.storageKey: jsonEncode({
            'order': [
              MainTabId.profile.id,
              ...MainTabId.values
                  .where((tab) => tab != MainTabId.profile)
                  .map((tab) => tab.id),
            ],
            'hidden': [tab.id],
          }),
        },
      );
      final profileElement = tester.element(find.byType(ProfileScreen));
      final tabs = profileElement.read<MainTabProvider>();
      final prefs = await SharedPreferences.getInstance();
      final savedSettings = prefs.getString(MainTabProvider.storageKey);
      final pageType = switch (tab) {
        MainTabId.record => HomeScreen,
        MainTabId.diary => DiaryScreen,
        MainTabId.travel => TravelScreen,
        MainTabId.checkIn => CheckInScreen,
        MainTabId.target => TargetScreen,
        MainTabId.profile => ProfileScreen,
      };

      expect(find.byType(pageType, skipOffstage: false), findsNothing);
      expect(_tab(tab.label), findsNothing);
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('hidden-main-tab-${tab.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(pageType), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      final pageElement = tester.element(find.byType(pageType));
      if (tab == MainTabId.diary) {
        expect(find.byTooltip('浏览远程日记'), findsOneWidget);
        expect(
            find.byWidgetPredicate((widget) =>
                widget is Tooltip &&
                (widget.message?.startsWith('搜索日记') ?? false)),
            findsOneWidget);
        await tester.tap(find.byTooltip('浏览远程日记'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(Drawer), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(Drawer), findsNothing);
        expect(find.byType(DiaryScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
      } else if (tab == MainTabId.record) {
        await tester.tap(find.byTooltip('记录工具'));
        await tester.pumpAndSettle();
        expect(find.text('撤销'), findsOneWidget);
        expect(find.text('查看对方日程'), findsOneWidget);
        expect(find.text('同步日程'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
      }

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(ProfileScreen)), same(profileElement));
      expect(_tab(tab.label), findsNothing);
      expect(tabs.hiddenTabs, {tab});
      expect(prefs.getString(MainTabProvider.storageKey), savedSettings);

      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('hidden-main-tab-${tab.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.element(find.byType(pageType)), same(pageElement));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(ProfileScreen)), same(profileElement));
      expect(_tab(tab.label), findsNothing);
      expect(prefs.getString(MainTabProvider.storageKey), savedSettings);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final surfaceOpacity in [0.2, AppSurfaces.defaultSurfaceOpacity]) {
      testWidgets('更多功能菜单在 $brightness / $surfaceOpacity 壁纸模式下保持不透明',
          (tester) async {
        final theme = AppTheme.themeFor(
          brightness,
          backgroundEnabled: true,
          surfaceOpacity: surfaceOpacity,
        );
        await _pumpMainScreen(
          tester,
          createProvider: _CountingProvider.new,
          theme: theme,
          initialPreferences: {
            MainTabProvider.storageKey: jsonEncode({
              'order': [
                'profile',
                'record',
                'diary',
                'travel',
                'check_in',
                'target'
              ],
              'hidden': ['travel', 'check_in'],
            }),
          },
        );
        await tester.tap(find.byTooltip('更多功能'));
        await tester.pumpAndSettle();

        final menuMaterial = tester.widget<Material>(find
            .ancestor(
              of: find.byKey(const ValueKey('hidden-main-tab-travel')),
              matching: find.byType(Material),
            )
            .first);
        expect(menuMaterial.color, theme.extension<AppSurfaces>()!.overlay);
        expect(menuMaterial.color!.a, 1);
        expect(find.byKey(const ValueKey('hidden-main-tab-check_in')),
            findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('桌面更多功能仅按自定义顺序列出隐藏页，恢复显示后入口消失', (tester) async {
    await _pumpMainScreen(
      tester,
      screenSize: const Size(1200, 800),
      initialPreferences: {
        MainTabProvider.storageKey: jsonEncode({
          'order': [
            'target',
            'profile',
            'travel',
            'check_in',
            'diary',
            'record'
          ],
          'hidden': ['diary', 'travel', 'check_in', 'target'],
        }),
      },
    );
    final tabs =
        tester.element(find.byType(MainScreen)).read<MainTabProvider>();
    await tester.tap(find.byTooltip('更多功能'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<PopupMenuItem<MainTabId>>(
              find.byType(PopupMenuItem<MainTabId>))
          .where((item) => item.enabled)
          .map((item) => item.value),
      [MainTabId.target, MainTabId.travel, MainTabId.checkIn, MainTabId.diary],
    );
    await tester.tap(find.byKey(const ValueKey('hidden-main-tab-target')));
    await tester.pumpAndSettle();
    expect(find.byType(TargetScreen), findsOneWidget);
    final targetElement = tester.element(find.byType(TargetScreen));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tabs.save(order: tabs.order, hiddenTabs: {});
    await tester.pumpAndSettle();
    expect(find.byTooltip('更多功能'), findsNothing);
    await tester.tap(_tab('目标'));
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(TargetScreen)), same(targetElement));
    expect(find.byType(BackButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(360, 800), const Size(1200, 800)]) {
    testWidgets('$size 按已保存的顺序启动，隐藏页不构造且点击对应正确页面', (tester) async {
      await _pumpMainScreen(
        tester,
        screenSize: size,
        initialPreferences: {
          MainTabProvider.storageKey: jsonEncode({
            'order': [
              'target',
              'diary',
              'profile',
              'check_in',
              'record',
              'travel'
            ],
            'hidden': ['record', 'travel'],
          }),
        },
      );

      expect(find.byType(TargetScreen), findsOneWidget);
      expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
      expect(find.byType(TravelScreen, skipOffstage: false), findsNothing);
      expect(_tab('记录'), findsNothing);
      expect(_tab('出行'), findsNothing);
      expect(
        tester
            .widgetList<NavigationDestination>(
                find.byType(NavigationDestination))
            .map((destination) => destination.label),
        ['目标', '日记', '我的', '打卡'],
      );
      await tester.tap(_tab('日记'));
      await tester.pump();
      expect(find.byType(DiaryScreen), findsOneWidget);
      await tester.tap(_tab('我的'));
      await tester.pump();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('排序保留选中的页面与状态，隐藏当前页后切换且恢复时仍保活', (tester) async {
    await _pumpMainScreen(tester);
    await tester.tap(_tab('日记'));
    await tester.pump();
    final diaryElement = tester.element(find.byType(DiaryScreen));
    final tabs =
        tester.element(find.byType(MainScreen)).read<MainTabProvider>();
    final reordered = [
      MainTabId.diary,
      MainTabId.profile,
      MainTabId.target,
      MainTabId.record,
      MainTabId.travel,
      MainTabId.checkIn,
    ];

    await tabs.save(order: reordered, hiddenTabs: {});
    await tester.pump();
    expect(tester.element(find.byType(DiaryScreen)), same(diaryElement));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );

    await tabs.save(order: reordered, hiddenTabs: {MainTabId.diary});
    await tester.pump();
    expect(_tab('日记'), findsNothing);
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(
      tester.element(find.byType(DiaryScreen, skipOffstage: false)),
      same(diaryElement),
    );

    await tester.tap(find.byTooltip('更多功能'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hidden-main-tab-diary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.element(find.byType(DiaryScreen)), same(diaryElement));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);

    await tabs.save(order: reordered, hiddenTabs: {});
    await tester.pump();
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    await tester.tap(_tab('日记'));
    await tester.pump();
    expect(tester.element(find.byType(DiaryScreen)), same(diaryElement));
    expect(tester.takeException(), isNull);
  });

  testWidgets('从我的页设置隐藏和排序，保存后立即更新主导航并留在原页面', (tester) async {
    await _pumpMainScreen(tester);
    await tester.tap(_tab('我的'));
    await tester.pump();
    final profileElement = tester.element(find.byType(ProfileScreen));
    final profileScaffold = tester.state<ScaffoldState>(find.descendant(
      of: find.byType(ProfileScreen),
      matching: find.byType(Scaffold),
    ));
    profileScaffold.openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('外观设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('底部标签'));
    await tester.pumpAndSettle();
    expect(find.byType(MainTabSettingsScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('main-tab-switch-record')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('调整顺序：我的'));
    await tester.tap(find.byTooltip('调整顺序：我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.byType(MainTabSettingsScreen), findsNothing);
    expect(tester.element(find.byType(ProfileScreen)), same(profileElement));
    expect(
      tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((destination) => destination.label),
      ['日记', '出行', '打卡', '我的', '目标'],
    );
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏我的页不查询统计，返回后更新数据并保留筛选状态', (tester) async {
    AppIdentityService.resetForTesting();
    addTearDown(AppIdentityService.resetForTesting);
    final focus = Category(
      id: 'focus',
      name: '专注',
      color: const Color(0xFF9CB86A),
      updatedAt: 1,
    );
    final provider = await _pumpMainScreen(
      tester,
      createProvider: _CountingProvider.new,
      initialPreferences: {
        AppIdentityService.modeKey: 'manual',
        AppIdentityService.legacyScheduleUserKey: 'g',
        'categories': [jsonEncode(focus.toJson())],
      },
    ) as _CountingProvider;
    await tester.runAsync(provider.waitForSyncReady);
    await tester.tap(_tab('我的'));
    await tester.pump();
    final profileElement = tester.element(find.byType(ProfileScreen));
    expect(provider.dailyCalls, greaterThan(0));
    expect(provider.statsCalls, 2, reason: '趋势不能再发出30次逐日分类统计查询');
    await tester.tap(find.descendant(
      of: find.byType(TabBar),
      matching: find.text('总览'),
    ));
    await tester.pump();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
    await tester.tap(_tab('记录'));
    await tester.pump();
    provider.resetCounters();
    provider.notifyStatusOnly();
    await tester.pump();
    expect(provider.statsCalls, 0);
    expect(provider.dailyCalls, 0);
    await tester.runAsync(() async {
      provider.assignCategoryToSlots({48}, focus);
    });
    await tester.pump();
    expect(provider.statsCalls, 0);
    expect(provider.dailyCalls, 0);
    await tester.tap(_tab('我的'));
    await tester.pump();
    expect(tester.element(find.byType(ProfileScreen)), same(profileElement));
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
    expect(provider.statsCalls, greaterThan(0));
    expect(provider.lastDailyStatistics!.last.hours, closeTo(1 / 6, 1e-9));
    expect(find.text(focus.name), findsWidgets);
  });

  testWidgets('临时打开隐藏页时暂停我的页统计，返回后恢复并保留筛选', (tester) async {
    final provider = await _pumpMainScreen(
      tester,
      createProvider: _CountingProvider.new,
      initialPreferences: {
        MainTabProvider.storageKey: jsonEncode({
          'order': [
            'profile',
            'record',
            'diary',
            'travel',
            'check_in',
            'target'
          ],
          'hidden': ['target'],
        }),
      },
    ) as _CountingProvider;
    await tester.tap(find.descendant(
      of: find.byType(TabBar),
      matching: find.text('总览'),
    ));
    await tester.pump();
    await tester.tap(find.byTooltip('更多功能'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hidden-main-tab-target')));
    await tester.pumpAndSettle();
    provider.resetCounters();
    provider.notifyStatusOnly();
    await tester.pump();
    expect(provider.statsCalls, 0);
    expect(provider.dailyCalls, 0);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(provider.statsCalls, greaterThan(0));
    expect(provider.dailyCalls, greaterThan(0));
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
    expect(tester.takeException(), isNull);
  });
}
