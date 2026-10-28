import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/background_image_provider.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/providers/desktop_shortcut_provider.dart';
import 'package:time_manager/providers/main_tab_provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/app_log_screen.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'package:time_manager/services/on_this_day_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/data_failure_banner.dart';

/// 壳层「数据故障」横幅的验收测试。
///
/// 两类故障都曾经静默：初始化失败后编辑全变 no-op，时间块保存失败只写日志。
/// 横幅放在 [MainScreen] 内容区顶部，底部标签隐藏「记录」页时也仍然可见。

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

ScheduleSyncDependencies _offlineDependencies() => ScheduleSyncDependencies(
      loadToken: () async => 'fake-token',
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.error('测试禁用远端'),
      pullDay: ({required token, required dateKey, required userCode}) async =>
          ScheduleGiteePullResult.error('测试禁用远端'),
    );

void _installPluginMocks(
  Map<String, Object> prefs, {
  String? manualIdentityCode,
}) {
  SharedPreferences.setMockInitialValues({
    'on_this_day_last_shown_date': OnThisDayService.dateKeyOf(DateTime.now()),
    ...prefs,
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
    (call) async {
      final arguments = call.arguments;
      if (manualIdentityCode != null &&
          call.method == 'read' &&
          arguments is Map &&
          arguments['key'] == 'app_user_identity_manual_kind') {
        return manualIdentityCode;
      }
      return null;
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_failure_banner_test',
  );
}

Future<void> _pumpMainScreen(
  WidgetTester tester,
  TimeProvider provider, {
  Size size = const Size(360, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const MainScreen(),
      ),
    ),
  );
  for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

/// 构造一个初始化必然失败的 Provider：截断的覆盖日志会让启动恢复校验失败。
Future<TimeProvider> _failedInitProvider(
  WidgetTester tester, {
  Map<String, Object> extraPrefs = const {},
}) async {
  _installPluginMocks({
    'daily_slots': '{"2026-01-01":[{"i":0,"l":"必须保留","c":2,"ts":1000}]}',
    'schedule_overwrite_transaction_journal': '{"phase":"prepared","before":',
    'schedule_user_kind': 'g',
    ...extraPrefs,
  }, manualIdentityCode: 'g');
  final provider = TimeProvider(
    scheduleSyncDependencies: _offlineDependencies(),
    identityModePlatformOverride: false,
    googleCalendarSyncPlatformOverride: false,
  );
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 100));
  return provider;
}

void main() {
  group('DataFailureBanner', () {
    Future<void> pumpBanner(
      WidgetTester tester, {
      String title = '本地保存失败，最近的修改可能丢失',
      String? message,
      String? actionLabel,
      VoidCallback? onAction,
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
            body: DataFailureBanner(
              title: title,
              message: message,
              actionLabel: actionLabel,
              onAction: onAction,
            ),
          ),
        ),
      );
    }

    testWidgets('显示标题、原因与操作按钮', (tester) async {
      await pumpBanner(
        tester,
        message: '本地数据保存失败，最近的修改可能丢失',
        actionLabel: '重试保存',
        onAction: () {},
      );

      expect(find.text('本地保存失败，最近的修改可能丢失'), findsOneWidget);
      expect(find.text('本地数据保存失败，最近的修改可能丢失'), findsOneWidget);
      expect(find.text('重试保存'), findsOneWidget);
    });

    testWidgets('没有原因时退回通用提示', (tester) async {
      await pumpBanner(tester);

      expect(find.textContaining('请重启应用后再试'), findsOneWidget);
      // 没有回调时不渲染按钮，避免点了没反应
      expect(find.text('重试保存'), findsNothing);
    });

    testWidgets('点击操作按钮触发回调', (tester) async {
      var taps = 0;
      await pumpBanner(tester, actionLabel: '重试保存', onAction: () => taps++);

      await tester.tap(find.text('重试保存'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('启用背景图时表面按界面不透明度半透明', (tester) async {
      const opacity = 0.6;
      await pumpBanner(
        tester,
        theme: AppTheme.light(backgroundEnabled: true, surfaceOpacity: opacity),
      );

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(DataFailureBanner),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color!.a, closeTo(opacity, 0.001));
      final card = AppSurfaces.of(
        tester.element(find.byType(DataFailureBanner)),
      ).card;
      expect(decoration.color!.r, closeTo(card.r, 0.001));
    });

    testWidgets('窄屏大字下不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpBanner(
        tester,
        message: '覆盖日程提交日志与本地数据不一致，请重启应用恢复',
        actionLabel: '查看日志',
        onAction: () {},
        textScale: 1.3,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('本地保存失败，最近的修改可能丢失'), findsOneWidget);
    });
  });

  group('主壳故障横幅', () {
    testWidgets('初始化失败时置顶显示横幅并可进入日志页', (tester) async {
      final provider = await _failedInitProvider(tester);
      expect(provider.hasInitializationFailure, isTrue);
      await _pumpMainScreen(tester, provider);

      expect(find.byType(DataFailureBanner), findsOneWidget);
      expect(find.text('本地数据未能加载，编辑已暂停'), findsOneWidget);
      final message = provider.initializationFailureMessage!;
      expect(find.text(message), findsOneWidget);

      await tester.tap(find.text('查看日志'));
      await tester.pumpAndSettle();
      expect(find.byType(AppLogScreen), findsOneWidget);
    });

    testWidgets('隐藏「记录」页时横幅仍然可见', (tester) async {
      final provider = await _failedInitProvider(
        tester,
        extraPrefs: {
          MainTabProvider.storageKey: jsonEncode({
            'order': ['record', 'diary', 'travel', 'checkin', 'target', 'profile'],
            'hidden': ['record', 'diary', 'travel', 'checkin'],
          }),
        },
      );
      await _pumpMainScreen(tester, provider);

      // 导航里没有「记录」，但失败提示仍然挂着
      expect(find.byType(DataFailureBanner), findsOneWidget);
      expect(find.text('本地数据未能加载，编辑已暂停'), findsOneWidget);
    });

    testWidgets('保存失败时提示并可重试成功', (tester) async {
      _installPluginMocks(const {});
      var failWrites = false;
      final provider = TimeProvider(
        identityModePlatformOverride: false,
        googleCalendarSyncPlatformOverride: false,
        localSaveDebounce: const Duration(hours: 1),
        scheduleSyncDependencies: _offlineDependencies(),
        saveDataOverride: () async => !failWrites,
      );
      await _pumpMainScreen(tester, provider);
      expect(find.byType(DataFailureBanner), findsNothing);

      failWrites = true;
      expect(await provider.retryLocalSave(), isFalse);
      await tester.pump();
      expect(provider.hasLocalSaveFailure, isTrue);
      expect(find.text('本地保存失败，最近的修改可能丢失'), findsOneWidget);
      expect(find.text('重试保存'), findsOneWidget);

      failWrites = false;
      await tester.tap(find.text('重试保存'));
      await tester.pump();
      await tester.pump();

      expect(provider.hasLocalSaveFailure, isFalse);
      expect(find.byType(DataFailureBanner), findsNothing);
    });

    testWidgets('重试仍然失败时给出明确反馈', (tester) async {
      _installPluginMocks(const {});
      final provider = TimeProvider(
        identityModePlatformOverride: false,
        googleCalendarSyncPlatformOverride: false,
        localSaveDebounce: const Duration(hours: 1),
        scheduleSyncDependencies: _offlineDependencies(),
        saveDataOverride: () async => false,
      );
      await _pumpMainScreen(tester, provider);

      expect(await provider.retryLocalSave(), isFalse);
      await tester.pump();
      await tester.tap(find.text('重试保存'));
      await tester.pump();
      await tester.pump();

      expect(find.text('仍然无法保存，请检查存储空间后重试'), findsOneWidget);
    });

    testWidgets('初始化与保存都正常时不渲染横幅', (tester) async {
      _installPluginMocks(const {});
      final provider = TimeProvider(
        identityModePlatformOverride: false,
        googleCalendarSyncPlatformOverride: false,
        scheduleSyncDependencies: _offlineDependencies(),
      );
      await _pumpMainScreen(tester, provider);

      expect(provider.hasInitializationFailure, isFalse);
      expect(provider.hasLocalSaveFailure, isFalse);
      expect(find.byType(DataFailureBanner), findsNothing);
    });
  });
}
