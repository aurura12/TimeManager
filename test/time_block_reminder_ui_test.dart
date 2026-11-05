import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/time_block_reminder.dart';
import 'package:time_manager/providers/background_image_provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/on_this_day_service.dart';
import 'package:time_manager/services/reminder_platform.dart';
import 'package:time_manager/services/time_block_reminder_service.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/profile_settings_drawer.dart';

import 'support/fake_reminder_backend.dart';

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
  late FakeReminderBackend backend;

  Map<String, Object> mockPrefs([Map<String, Object> extra = const {}]) {
    return <String, Object>{
      'on_this_day_last_shown_date': OnThisDayService.dateKeyOf(DateTime.now()),
      'schedule_user_kind': 'g',
      ...extra,
    };
  }

  void installMocks([Map<String, Object> extra = const {}]) {
    SharedPreferences.setMockInitialValues(mockPrefs(extra));
    GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in <String>[
      'home_widget',
      'plugins.it_nomads.com/flutter_secure_storage',
      'dev.fluttercommunity.plus/package_info',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (call) async => null);
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp/time_manager_drawer_test',
    );
  }

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required bool android,
  }) async {
    tester.view.physicalSize = const Size(400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TimeProvider>(create: (_) => TimeProvider()),
          ChangeNotifierProvider<ThemeModeProvider>(
            create: (_) => ThemeModeProvider(),
          ),
          ChangeNotifierProvider<BackgroundImageProvider>(
            create: (_) => BackgroundImageProvider(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: Scaffold(
            body: ProfileSettingsDrawer(
              onChanged: () {},
              androidPlatformOverride: android,
            ),
          ),
        ),
      ),
    );

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();
    if (android) {
      await tester.tap(find.text('提醒设置'));
      await tester.pumpAndSettle();
    }
  }

  setUp(() {
    installMocks();
    TimeBlockReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
    AppIdentityService.resetForTesting();

    backend = FakeReminderBackend();
    ReminderPlatform.backendOverride = backend;
    ReminderPlatform.androidPlatformOverride = true;
    ReminderPlatform.timezoneIdentifierOverride = () async => 'Asia/Shanghai';
    AppIdentityService.adoptManualKind(DiaryKind.g);
  });

  tearDown(() {
    TimeBlockReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
    AppIdentityService.resetForTesting();
  });

  testWidgets('Android 上渲染时间块提醒分区，默认关闭', (tester) async {
    await pumpDrawer(tester, android: true);

    expect(find.text('时间块提醒'), findsOneWidget);
    expect(find.text('提前量'), findsOneWidget);
    expect(find.text('已关闭'), findsNWidgets(2));
    expect(find.text('发送测试通知'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('非 Android 平台不渲染时间块提醒', (tester) async {
    await pumpDrawer(tester, android: false);

    expect(find.text('时间块提醒'), findsNothing);
    expect(find.text('提前量'), findsNothing);
  });

  testWidgets('已开启时显示提前量与登记条数', (tester) async {
    SharedPreferences.setMockInitialValues(mockPrefs(<String, Object>{
      'identity_g_time_block_reminder_enabled': true,
      'identity_g_time_block_reminder_lead_minutes': 10,
    }));
    AppIdentityService.resetForTesting();
    TimeBlockReminderService.attachScheduleSource(
      () => <TimeBlockReminderDay>[],
    );

    await pumpDrawer(tester, android: true);

    expect(find.text('提前 10 分钟'), findsOneWidget);
    expect(find.text('已开启 · 提前 10 分钟 · 未来 3 天 0 个提醒'), findsOneWidget);
  });

  testWidgets('未选身份时开关置灰并提示先选身份', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'on_this_day_last_shown_date': OnThisDayService.dateKeyOf(DateTime.now()),
    });
    AppIdentityService.resetForTesting();

    await pumpDrawer(tester, android: true);

    expect(find.text('请先选择用户身份'), findsWidgets);
    final switches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.every((tile) => tile.onChanged == null), isTrue);
  });

  testWidgets('打开开关会写入身份作用域的偏好', (tester) async {
    TimeBlockReminderService.attachScheduleSource(
      () => <TimeBlockReminderDay>[],
    );

    await pumpDrawer(tester, android: true);
    await tester.tap(find.text('时间块提醒'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('identity_g_time_block_reminder_enabled'), isTrue);
    expect(find.text('已开启 · 提前 5 分钟 · 未来 3 天 0 个提醒'), findsOneWidget);
  });
}
