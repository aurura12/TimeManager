import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/app_log_screen.dart';
import 'package:time_manager/screens/home_screen.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/initialization_failure_banner.dart';

/// 首页「本地数据未能加载」横幅的验收测试。
///
/// 背景：初始化失败后 `TimeProvider` 把编辑全部变成 no-op，首页却和空白的一天
/// 长得一样。横幅必须出现、必须带原因、必须能进日志页，否则用户只会觉得应用坏了。

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

/// 测试里不能真的连 Gitee：所有远端调用直接报错。
ScheduleSyncDependencies _offlineDependencies() => ScheduleSyncDependencies(
      loadToken: () async => 'fake-token',
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.error('测试禁用远端'),
      pullDay: ({required token, required dateKey, required userCode}) async =>
          ScheduleGiteePullResult.error('测试禁用远端'),
    );

void _installPluginMocks(Map<String, Object> prefs) {
  SharedPreferences.setMockInitialValues(prefs);
  GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async {
      final arguments = call.arguments;
      // 让日程层按「乖乖」身份启动，才能走到覆盖日志校验那条失败路径
      if (call.method == 'read' &&
          arguments is Map &&
          arguments['key'] == 'app_user_identity_manual_kind') {
        return 'g';
      }
      return null;
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_init_failure_test',
  );
}

Future<TimeProvider> _createFailedProvider(WidgetTester tester) async {
  _installPluginMocks({
    'daily_slots': '{"2026-01-01":[{"i":0,"l":"必须保留","c":2,"ts":1000}]}',
    // 截断的覆盖日志会让启动时的恢复校验失败
    'schedule_overwrite_transaction_journal': '{"phase":"prepared","before":',
    'schedule_user_kind': 'g',
  });
  final provider = TimeProvider(scheduleSyncDependencies: _offlineDependencies());
  addTearDown(provider.dispose);
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 100));
  return provider;
}

Future<void> _pumpHome(WidgetTester tester, TimeProvider provider) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<TimeProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => DesktopLayoutProvider()),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  group('InitializationFailureBanner', () {
    Future<void> pumpBanner(
      WidgetTester tester, {
      String? message,
      VoidCallback? onViewLogs,
      ThemeData? theme,
      double textScale = 1.0,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme ?? AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: InitializationFailureBanner(
              message: message,
              onViewLogs: onViewLogs,
            ),
          ),
        ),
      );
    }

    testWidgets('显示标题、失败原因与日志入口', (tester) async {
      await pumpBanner(
        tester,
        message: '本地日程恢复失败，请检查本地数据后重试',
        onViewLogs: () {},
      );

      expect(find.text(InitializationFailureBanner.title), findsOneWidget);
      expect(find.text('本地日程恢复失败，请检查本地数据后重试'), findsOneWidget);
      expect(find.text('查看日志'), findsOneWidget);
    });

    testWidgets('没有失败原因时退回通用提示', (tester) async {
      await pumpBanner(tester);

      expect(find.text(InitializationFailureBanner.title), findsOneWidget);
      expect(find.textContaining('请重启应用后再试'), findsOneWidget);
      // 没有回调时不渲染按钮，避免点了没反应
      expect(find.text('查看日志'), findsNothing);
    });

    testWidgets('点击查看日志触发回调', (tester) async {
      var taps = 0;
      await pumpBanner(tester, message: '恢复失败', onViewLogs: () => taps++);

      await tester.tap(find.text('查看日志'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('启用背景图时表面按界面不透明度半透明', (tester) async {
      const opacity = 0.6;
      await pumpBanner(
        tester,
        message: '恢复失败',
        theme: AppTheme.light(backgroundEnabled: true, surfaceOpacity: opacity),
      );

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(InitializationFailureBanner),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color!.a, closeTo(opacity, 0.001));
      // 填充必须来自卡片面，不能是原始 danger 色
      expect(decoration.color!.r, closeTo(
          AppSurfaces.of(tester.element(find.byType(InitializationFailureBanner)))
              .card
              .r,
          0.001));
    });

    testWidgets('窄屏大字下不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpBanner(
        tester,
        message: '覆盖日程提交日志与本地数据不一致，请重启应用恢复',
        onViewLogs: () {},
        textScale: 1.3,
      );

      expect(tester.takeException(), isNull);
      expect(find.text(InitializationFailureBanner.title), findsOneWidget);
    });
  });

  group('首页接入', () {
    testWidgets('初始化失败时首页置顶显示横幅并给出原因', (tester) async {
      final provider = await _createFailedProvider(tester);
      expect(provider.hasInitializationFailure, isTrue);

      await _pumpHome(tester, provider);

      expect(find.byType(InitializationFailureBanner), findsOneWidget);
      expect(find.text(InitializationFailureBanner.title), findsOneWidget);
      final message = provider.initializationFailureMessage;
      expect(message, isNotNull);
      expect(find.text(message!), findsOneWidget);
    });

    testWidgets('点查看日志进入运行日志页', (tester) async {
      final provider = await _createFailedProvider(tester);
      await _pumpHome(tester, provider);

      await tester.tap(find.text('查看日志'));
      await tester.pumpAndSettle();

      expect(find.byType(AppLogScreen), findsOneWidget);
    });

    testWidgets('初始化成功时首页不渲染横幅', (tester) async {
      _installPluginMocks(const {});
      final provider = TimeProvider(
        scheduleSyncDependencies: _offlineDependencies(),
      );
      addTearDown(provider.dispose);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!provider.isInitialLoadFinished &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(provider.hasInitializationFailure, isFalse);

      await _pumpHome(tester, provider);

      expect(find.byType(InitializationFailureBanner), findsNothing);
    });
  });
}
