import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/check_in_screen.dart';
import 'package:time_manager/screens/diary_screen.dart';
import 'package:time_manager/screens/home_screen.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'package:time_manager/screens/profile_screen.dart';
import 'package:time_manager/screens/target_screen.dart';
import 'package:time_manager/screens/travel_screen.dart';
import 'package:time_manager/services/on_this_day_service.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/utils/platform_features.dart';

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

void _installPluginMocks() {
  SharedPreferences.setMockInitialValues({
    'on_this_day_last_shown_date': OnThisDayService.dateKeyOf(DateTime.now()),
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

Future<void> _pumpMainScreen(WidgetTester tester) async {
  _installPluginMocks();
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final provider = TimeProvider();
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

    if (isDesktopPlatform) {
      expect(_tab('目标'), findsNothing);
    }
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
  });

  testWidgets('平台过滤后的最后一个 Tab 仍导航到我的页面', (tester) async {
    await _pumpMainScreen(tester);

    await tester.tap(_tab('我的'));
    await tester.pump();

    expect(find.byType(ProfileScreen), findsOneWidget);
    final navigationBar = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    expect(navigationBar.selectedIndex, isDesktopPlatform ? 4 : 5);
    expect(_tab('我的'), findsOneWidget);
  });
}
