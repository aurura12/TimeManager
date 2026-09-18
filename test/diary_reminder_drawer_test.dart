import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/diary_reminder_service.dart';
import 'package:time_manager/services/on_this_day_service.dart';
import 'package:time_manager/services/reminder_platform.dart';
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

  /// 抽屉里会创建 TimeProvider，而它的初始化会跑 `AppIdentityService.load()`。
  /// 这个方法**每次都会重新读偏好**，所以身份必须放在偏好里（而不是靠
  /// `adoptManualKind` 设进去），否则会被 load 覆盖成「未选身份」。
  /// `schedule_user_kind` 就是 load 认的迁移键。
  Map<String, Object> mockPrefs([Map<String, Object> extra = const {}]) {
    return <String, Object>{
      'on_this_day_last_shown_date':
          OnThisDayService.dateKeyOf(DateTime.now()),
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
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp/time_manager_drawer_test',
    );
  }

  /// 单独渲染设置抽屉。放进 body 而不是 Scaffold.drawer，
  /// 这样不用先展开抽屉，也不依赖汉堡按钮。
  Future<void> pumpDrawer(
    WidgetTester tester, {
    required bool android,
  }) async {
    // 视口给足高度：抽屉是长 ListView，懒构建会让折叠线以下的条目根本不挂载
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

    // 等抽屉里的异步状态加载完成
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();
  }

  setUp(() {
    installMocks();
    DiaryReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
    AppIdentityService.resetForTesting();

    backend = FakeReminderBackend();
    ReminderPlatform.backendOverride = backend;
    ReminderPlatform.androidPlatformOverride = true;
    ReminderPlatform.timezoneIdentifierOverride = () async => 'Asia/Shanghai';
    AppIdentityService.adoptManualKind(DiaryKind.g);
  });

  tearDown(() {
    DiaryReminderService.resetForTesting();
    ReminderPlatform.resetForTesting();
    AppIdentityService.resetForTesting();
  });

  testWidgets('Android 上显示提醒分区与默认时间', (tester) async {
    await pumpDrawer(tester, android: true);

    expect(find.text('提醒'), findsOneWidget);
    expect(find.text('写日记提醒'), findsOneWidget);
    expect(find.text('提醒时间'), findsOneWidget);
    expect(find.text('21:00'), findsOneWidget);
    expect(find.text('发送测试通知'), findsOneWidget);
    expect(find.text('已关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非 Android 平台不渲染提醒分区', (tester) async {
    await pumpDrawer(tester, android: false);

    expect(find.text('提醒'), findsNothing);
    expect(find.text('写日记提醒'), findsNothing);
    expect(find.text('提醒时间'), findsNothing);
    expect(find.text('发送测试通知'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开开关会写入身份作用域的偏好并登记一次提醒', (tester) async {
    await pumpDrawer(tester, android: true);

    await tester.tap(find.text('写日记提醒'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('identity_g_diary_reminder_enabled'), isTrue);
    expect(prefs.getInt('identity_g_diary_reminder_hour'), 21);
    expect(backend.scheduledCalls, hasLength(1));
    expect(find.text('已开启 · 每天 21:00'), findsOneWidget);
  });

  testWidgets('未选身份时开关置灰并提示先选身份', (tester) async {
    // 偏好里不带身份键：load() 解析不出身份
    SharedPreferences.setMockInitialValues(<String, Object>{
      'on_this_day_last_shown_date':
          OnThisDayService.dateKeyOf(DateTime.now()),
    });
    AppIdentityService.resetForTesting();

    await pumpDrawer(tester, android: true);

    expect(find.text('请先选择上方用户身份'), findsOneWidget);
    final switchTile = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile).last,
    );
    expect(switchTile.onChanged, isNull, reason: '未选身份时不允许开启');
  });

  testWidgets('初始化失败时抽屉仍能打开并显示降级文案', (tester) async {
    backend.throwOnInitialize = true;

    await pumpDrawer(tester, android: true);

    // 抽屉必须照常渲染，异常不能抛进 build
    expect(tester.takeException(), isNull);
    expect(find.text('写日记提醒'), findsOneWidget);
    expect(find.text('提醒初始化失败，请查看运行日志'), findsOneWidget);
  });

  testWidgets('通知权限被拒时开关自动回滚为关闭', (tester) async {
    backend.notificationsAllowed = false;
    backend.notificationPermissionResult = false;

    await pumpDrawer(tester, android: true);
    await tester.tap(find.text('写日记提醒'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('identity_g_diary_reminder_enabled'),
      isFalse,
      reason: '不留下一个永远不会响的「已开启」',
    );
    expect(backend.scheduledCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺少精确闹钟权限时保留开启并提示可能延迟', (tester) async {
    backend.exactAllowed = false;

    await pumpDrawer(tester, android: true);
    await tester.tap(find.text('写日记提醒'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('已开启（可能延迟几分钟）'), findsOneWidget);
    // SnackBar 与告警行会同时展示这段说明
    expect(
      find.text('缺少精确闹钟权限，提醒可能延迟几分钟。点按前往系统设置。'),
      findsWidgets,
    );
    // 开关 → 申请权限 → 重排，会登记两次；但两次用的是同一个 ID，
    // 且中间先取消，所以最终系统里只有一个待发提醒，不会重复弹。
    expect(
      backend.scheduledCalls.map((call) => call.id).toSet(),
      <int>{DiaryReminderService.notificationId},
    );
    expect(backend.cancelledIds, contains(DiaryReminderService.notificationId));
  });

  testWidgets('点「提醒时间」打开滚轮面板，确定后写入并重排', (tester) async {
    await pumpDrawer(tester, android: true);

    // 提醒关闭时时间项是禁用的，先打开开关
    await tester.tap(find.text('写日记提醒'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    backend.scheduledCalls.clear();

    await tester.tap(find.text('提醒时间'));
    await tester.pumpAndSettle();

    // 是自研滚轮面板，而不是系统时钟表盘
    expect(find.byKey(const ValueKey('time-wheel-hour')), findsOneWidget);
    expect(find.byKey(const ValueKey('time-wheel-minute')), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('time-wheel-hour')),
      const Offset(0, -44),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('identity_g_diary_reminder_hour'), 22);
    expect(find.text('已开启 · 每天 22:00'), findsOneWidget);
    expect(backend.scheduledCalls, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚轮面板点取消不改时间', (tester) async {
    await pumpDrawer(tester, android: true);

    await tester.tap(find.text('写日记提醒'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    await tester.tap(find.text('提醒时间'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('time-wheel-hour')),
      const Offset(0, -44),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('identity_g_diary_reminder_hour'), 21);
    expect(find.text('已开启 · 每天 21:00'), findsOneWidget);
  });

  testWidgets('已开启时再次进入抽屉会显示已保存的时间', (tester) async {
    SharedPreferences.setMockInitialValues(mockPrefs(<String, Object>{
      'identity_g_diary_reminder_enabled': true,
      'identity_g_diary_reminder_hour': 8,
      'identity_g_diary_reminder_minute': 30,
    }));
    backend.pending = <PendingNotificationRequest>[
      const PendingNotificationRequest(
        DiaryReminderService.notificationId,
        null,
        null,
        DiaryReminderService.payload,
      ),
    ];

    await pumpDrawer(tester, android: true);

    expect(find.text('08:30'), findsOneWidget);
    expect(find.text('已开启 · 每天 08:30'), findsOneWidget);
  });
}
