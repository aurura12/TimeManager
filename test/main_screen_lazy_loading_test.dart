import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/check_in_screen.dart';
import 'package:time_manager/screens/diary_screen.dart';
import 'package:time_manager/screens/home_screen.dart';
import 'package:time_manager/screens/main_screen.dart';
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
}) async {
  _installPluginMocks(initialPreferences);
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final provider = createProvider?.call() ?? TimeProvider();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });

  await tester.pumpWidget(
    ChangeNotifierProvider<TimeProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
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
}
