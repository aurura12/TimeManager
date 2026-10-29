import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/home_screen.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/utils/timeline_geometry.dart';

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
    'categories': <String>[],
    'daily_slots': jsonEncode(<String, Object>{}),
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
    (call) async => '/tmp/time_manager_now_scroll_test',
  );
}

final _axisFinder = find.byKey(const ValueKey('home-time-axis'));

ScrollController _axis(WidgetTester tester) =>
    tester.widget<ListView>(_axisFinder).controller!;

double _expectedOffset(WidgetTester tester, DateTime now) {
  final position = _axis(tester).position;
  return timelineScrollOffsetForNow(
    minutesOfDay: minutesOfDayOf(now),
    rowExtent: AppSizes.gridRow,
    topPadding: AppSpacing.sm,
    viewportExtent: position.viewportDimension,
    maxScrollExtent: position.maxScrollExtent,
  );
}

Future<TimeProvider> _pumpHome(
  WidgetTester tester, {
  required DateTime Function() clock,
}) async {
  _installPluginMocks();
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final provider = TimeProvider();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<TimeProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => DesktopLayoutProvider()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: HomeScreen(clock: clock),
      ),
    ),
  );
  for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
  await tester.pump(const Duration(seconds: 5));
  return provider;
}

DateTime _day(DateTime base, int delta) =>
    DateTime(base.year, base.month, base.day + delta);

void main() {
  testWidgets('首次打开滚到「现在」附近', (tester) async {
    final now = DateTime(2026, 10, 29, 15, 30);
    await _pumpHome(tester, clock: () => now);

    expect(_axis(tester).offset, closeTo(_expectedOffset(tester, now), 0.5));
    expect(_axis(tester).offset, greaterThan(0));
  });

  testWidgets('停在历史日期时保持用户滚动位置', (tester) async {
    final now = DateTime(2026, 10, 29, 15, 30);
    final provider = await _pumpHome(tester, clock: () => now);

    _axis(tester).jumpTo(0);
    await tester.pump();

    provider.goToDate(_day(now, -1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_axis(tester).offset, 0);
  });

  testWidgets('从别的日期切回今天会重新定位', (tester) async {
    final now = DateTime(2026, 10, 29, 15, 30);
    final provider = await _pumpHome(tester, clock: () => now);

    provider.goToDate(_day(now, -1));
    await tester.pump();
    expect(provider.currentDate, _day(now, -1), reason: '应能切到昨天');
    _axis(tester).jumpTo(0);
    await tester.pump();

    provider.goToDate(_day(now, 0));
    await tester.pump();
    expect(provider.currentDate, _day(now, 0), reason: '应能切回今天');
    // 定位动画在 post-frame 里启动，需要再走两帧才滚完。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(_axis(tester).offset, closeTo(_expectedOffset(tester, now), 1));
  });
}
