import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:home_widget/home_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'providers/time_provider.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'screens/global_search_screen.dart';
import 'services/app_log_service.dart';
import 'services/home_widget_action_router.dart';
import 'services/home_widget_service.dart';
import 'services/windows_legacy_preferences_migration.dart';
import 'widgets/desktop_shortcut_host.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// 自定义 HttpOverrides，解决部分 Android 设备（特别是 MIUI）上
/// HttpClient 的 SSL 握手不稳定问题。
class _StableHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // 延长连接超时，避免弱网环境下的频繁超时
    client.connectionTimeout = const Duration(seconds: 20);
    // 延长空闲超时，减少连接断开后重新 SSL 握手
    client.idleTimeout = const Duration(seconds: 60);
    return client;
  }
}

void installGlobalLogErrorHandlers(AppLogService service) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    service.error(
      'Flutter 未捕获异常',
      source: 'flutter',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    service.error(
      'Dart 未捕获异步异常',
      source: 'dart',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  };
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final migrationResult = await WindowsLegacyPreferencesMigration().migrate();
  if (migrationResult.didMigrate) {
    debugPrint(
      'Windows legacy preferences migrated: '
      '${migrationResult.migratedKeyCount} keys',
    );
  } else if (migrationResult.status == WindowsLegacyMigrationStatus.failed) {
    debugPrint(
      'Windows legacy preferences migration failed: '
      '${migrationResult.error}',
    );
  }
  final appLogService = AppLogService.instance;
  installGlobalLogErrorHandlers(appLogService);
  try {
    await appLogService.initialize();
  } catch (error, stackTrace) {
    debugPrint('应用日志初始化失败: $error\n$stackTrace');
    appLogService.error(
      '应用日志初始化失败',
      source: 'startup',
      error: error,
      stackTrace: stackTrace,
    );
  }
  HttpOverrides.global = _StableHttpOverrides();

  ErrorWidget.builder = (details) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 48, color: AppSemanticColors.dangerDeep),
                const SizedBox(height: 16),
                const Text('应用遇到了问题',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(details.exceptionAsString(), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => main(),
                  child: const Text('重启应用'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

  try {
    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (context) => TimeProvider()),
          ChangeNotifierProvider(create: (context) => ThemeModeProvider()),
        ],
        child: const TimeManagerApp(),
      ),
    );
  } catch (e, stackTrace) {
    debugPrint('应用启动失败: $e');
    appLogService.error(
      '应用启动失败',
      source: 'startup',
      error: e,
      stackTrace: stackTrace,
    );
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('启动失败: $e',
              style: const TextStyle(color: AppSemanticColors.dangerDeep)),
        ),
      ),
    ));
  }
}

class TimeManagerApp extends StatefulWidget {
  const TimeManagerApp({super.key});

  @override
  State<TimeManagerApp> createState() => _TimeManagerAppState();
}

class _TimeManagerAppState extends State<TimeManagerApp> {
  StreamSubscription<Uri?>? _homeWidgetClicks;
  HomeWidgetActionRequest? _pendingHomeWidgetAction;

  @override
  void initState() {
    super.initState();
    // home_widget 只在 Android 注册小组件点击通道；其他平台不触碰该
    // platform channel，避免启动时出现 MissingPluginException。
    if (Platform.isAndroid) {
      _homeWidgetClicks = HomeWidget.widgetClicked.listen(
        _handleHomeWidgetUri,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('监听小组件动作失败: $error');
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_readInitialHomeWidgetUri());
      });
    }
  }

  @override
  void dispose() {
    _homeWidgetClicks?.cancel();
    super.dispose();
  }

  Future<void> _readInitialHomeWidgetUri() async {
    try {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (mounted) _handleHomeWidgetUri(uri);
    } catch (error) {
      debugPrint('读取小组件启动动作失败: $error');
    }
  }

  void _handleHomeWidgetUri(Uri? uri) {
    final request = HomeWidgetService.parseActionUri(uri);
    if (request == null) return;

    _pendingHomeWidgetAction = request;
    _dispatchPendingHomeWidgetAction();
  }

  void _dispatchPendingHomeWidgetAction() {
    final request = _pendingHomeWidgetAction;
    if (request == null || !mounted) return;

    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _dispatchPendingHomeWidgetAction();
      });
      return;
    }

    _pendingHomeWidgetAction = null;
    unawaited(
      HomeWidgetActionRouter.dispatch(
        context: context,
        navigator: navigator,
        request: request,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<ThemeModeProvider>().themeMode;
    final timeProvider = context.read<TimeProvider>();
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      // 放在 Navigator 外层，保证 Dialog/BottomSheet 等临时路由也能用
      // Esc 关闭；HomeScreen 内层还会处理日期面板、刷子和时间选择。
      builder: (context, child) => DesktopShortcutHost(
        onUndo: timeProvider.undo,
        onPreviousDay: timeProvider.previousDay,
        onNextDay: timeProvider.nextDay,
        onToday: () => timeProvider.goToDate(DateTime.now()),
        onOpenSearch: () {
          final navigator = rootNavigatorKey.currentState;
          if (navigator == null) return;
          navigator.push(
            MaterialPageRoute(
              builder: (_) => const GlobalSearchScreen(),
            ),
          );
        },
        onEscape: () {
          final navigator = rootNavigatorKey.currentState;
          if (navigator == null || !navigator.canPop()) return false;
          navigator.pop();
          return true;
        },
        child: child ?? const SizedBox.shrink(),
      ),
      home: const MainScreen(),
    );
  }
}
