// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/main.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/screens/home_screen.dart';

/// 测试用的 GoogleSignInPlatform fake：所有方法返回安全默认值，
/// 避免 TimeProvider 初始化时 GoogleCalendarService.restoreSignIn 抛 UnimplementedError
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

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();

    // mock 插件方法通道，避免启动期触发原生调用失败
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
      (call) async => '/tmp/time_manager_test',
    );

    // 启动期会做真实文件 IO（日记索引缓存）与网络请求，
    // 这类真实异步在 fake-async 环境下无法完成，因此放在 runAsync 里跑真实事件循环。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => TimeProvider()),
            ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
          ],
          child: const TimeManagerApp(),
        ),
      );
      // 留出真实时间让启动期异步（文件 IO、Gitee 网络请求、Google 5s 恢复超时）收敛
      await Future<void>.delayed(const Duration(seconds: 10));
    });

    await tester.pump();

    expect(find.byType(TimeManagerApp), findsOneWidget);
  });

  testWidgets('首页不显示每日复盘入口', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
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
      (call) async => '/tmp/time_manager_test',
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => TimeProvider()),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });
}
