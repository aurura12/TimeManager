import 'dart:async';
import 'dart:convert';
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

enum SafeErrorPageKind {
  render,
  startup,
}

/// Controls a safe interface-only recovery after the application is running.
///
/// Bumping the generation recreates the current interface subtree while
/// retaining the existing provider instances. Startup recovery is handled by
/// [StartupRecoveryController] instead and performs a full startup attempt.
class AppRecoveryController extends ValueNotifier<int> {
  AppRecoveryController() : super(0);

  void reloadCurrentInterface() {
    value++;
  }
}

typedef StartupRetryCallback = Future<void> Function();

/// Runs a failed startup again without allowing duplicate concurrent attempts.
///
/// A retry is intentionally different from [AppRecoveryController]: it calls
/// the bootstrap callback, which recreates providers and reruns dependency
/// initialization instead of only rebuilding the error page.
class StartupRecoveryController {
  StartupRecoveryController(this._retryStartup);

  final StartupRetryCallback _retryStartup;
  bool _isRetrying = false;

  bool get isRetrying => _isRetrying;

  Future<void> retry() async {
    if (_isRetrying) return;
    _isRetrying = true;
    try {
      await _retryStartup();
    } finally {
      _isRetrying = false;
    }
  }
}

class AppRecoveryBoundary extends StatelessWidget {
  const AppRecoveryBoundary({
    required this.controller,
    required this.child,
    super.key,
  });

  final AppRecoveryController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller,
      child: child,
      builder: (context, generation, child) {
        return KeyedSubtree(
          key: ValueKey<int>(generation),
          child: child!,
        );
      },
    );
  }
}

String safeErrorTitle(SafeErrorPageKind kind) {
  switch (kind) {
    case SafeErrorPageKind.render:
      return '页面暂时无法显示';
    case SafeErrorPageKind.startup:
      return '应用暂时无法启动';
  }
}

String safeErrorDescription(SafeErrorPageKind kind) {
  switch (kind) {
    case SafeErrorPageKind.render:
      return '问题详情已记录。你可以返回上一页，或重新加载当前界面。';
    case SafeErrorPageKind.startup:
      return '问题详情已记录。重新加载会重新执行应用启动和依赖初始化。';
  }
}

String _normalizedErrorScope(String scope) {
  final normalized = scope.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (normalized.isEmpty) return 'ERR';
  return normalized.length > 8 ? normalized.substring(0, 8) : normalized;
}

int _errorFingerprint(String value) {
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 4294967295;
  }
  return hash;
}

/// Returns a short, non-sensitive identifier that can be searched in app logs.
///
/// The exception and stack trace are used only to derive the fingerprint. They
/// are never returned to the UI by this function.
String buildErrorReferenceCode({
  required String scope,
  required Object error,
  StackTrace? stackTrace,
}) {
  String errorText;
  try {
    errorText = error.toString();
  } catch (_) {
    errorText = error.runtimeType.toString();
  }
  final fingerprint = _errorFingerprint(
    '${_normalizedErrorScope(scope)}|$errorText|${stackTrace ?? ''}',
  ).toRadixString(16).toUpperCase().padLeft(8, '0');
  return '${_normalizedErrorScope(scope)}-$fingerprint';
}

String normalizeErrorReferenceCode(String value) {
  final normalized = value.trim().toUpperCase();
  final match = RegExp(r'^[A-Z][A-Z0-9]{0,7}-[0-9A-F]{8}$').firstMatch(
    normalized,
  );
  return match?.group(0) ?? 'ERR-00000000';
}

/// 根层 Esc 只允许关闭真正可关闭的顶层弹层。
///
/// 页面路由（例如添加/编辑表单）即使可以 pop，也不能被这个快捷键
/// 当作临时弹层关闭；输入框中的 Esc 因此不会静默丢弃整页表单。
bool isDismissiblePopupRoute(Route<dynamic>? route) {
  return route is PopupRoute && route.isCurrent && route.barrierDismissible;
}

class SafeErrorPage extends StatelessWidget {
  const SafeErrorPage({
    required this.kind,
    required this.errorCode,
    required this.onReload,
    super.key,
  });

  final SafeErrorPageKind kind;
  final String errorCode;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    final canReturn = navigator?.canPop() ?? false;

    return Theme(
      data: theme,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 48,
                        color: AppSemanticColors.dangerDeep,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        safeErrorTitle(kind),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        safeErrorDescription(kind),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        '错误编号：${normalizeErrorReferenceCode(errorCode)}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 20),
                      if (canReturn) ...[
                        OutlinedButton.icon(
                          onPressed: () {
                            final currentNavigator = Navigator.maybeOf(
                              context,
                              rootNavigator: true,
                            );
                            if (currentNavigator != null) {
                              unawaited(currentNavigator.maybePop());
                            }
                          },
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('返回上一页'),
                        ),
                        const SizedBox(height: 8),
                      ],
                      ElevatedButton.icon(
                        onPressed: onReload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新加载当前界面'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void installSafeErrorWidgetBuilder({
  required AppLogService service,
  required AppRecoveryController recoveryController,
}) {
  ErrorWidget.builder = (details) {
    final code = buildErrorReferenceCode(
      scope: 'UI',
      error: details.exception,
      stackTrace: details.stack,
    );
    service.error(
      '界面渲染失败 [$code]',
      source: 'flutter_ui',
      error: details.exception,
      stackTrace: details.stack,
    );
    return SafeErrorPage(
      kind: SafeErrorPageKind.render,
      errorCode: code,
      onReload: recoveryController.reloadCurrentInterface,
    );
  };
}

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
    final code = buildErrorReferenceCode(
      scope: 'UI',
      error: details.exception,
      stackTrace: details.stack,
    );
    service.error(
      'Flutter 未捕获异常 [$code]',
      source: 'flutter',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    final code = buildErrorReferenceCode(
      scope: 'DART',
      error: error,
      stackTrace: stackTrace,
    );
    service.error(
      'Dart 未捕获异步异常 [$code]',
      source: 'dart',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  };
}

void _runStartupFailurePage({
  required AppLogService service,
  required Object error,
  required StackTrace stackTrace,
  required StartupRetryCallback retryStartup,
}) {
  final code = buildErrorReferenceCode(
    scope: 'STARTUP',
    error: error,
    stackTrace: stackTrace,
  );
  service.error(
    '应用启动失败 [$code]',
    source: 'startup',
    error: error,
    stackTrace: stackTrace,
  );
  final retryController = StartupRecoveryController(retryStartup);
  runApp(
    MaterialApp(
      theme: AppTheme.light(),
      home: SafeErrorPage(
        kind: SafeErrorPageKind.startup,
        errorCode: code,
        onReload: () => unawaited(retryController.retry()),
      ),
    ),
  );
}

Future<void> _initializeAndRunApplication({
  required AppLogService appLogService,
  required AppRecoveryController recoveryController,
}) async {
  final migrationResult = await WindowsLegacyPreferencesMigration().migrate();
  if (migrationResult.didMigrate) {
    debugPrint(
      'Windows legacy preferences migrated: '
      '${migrationResult.migratedKeyCount} keys',
    );
  } else if (migrationResult.status == WindowsLegacyMigrationStatus.failed) {
    final code = buildErrorReferenceCode(
      scope: 'MIGRATE',
      error: migrationResult.error ?? StateError('migration failed'),
    );
    appLogService.error(
      'Windows legacy preferences migration failed [$code]',
      source: 'startup',
      error: migrationResult.error,
    );
  }

  try {
    await appLogService.initialize();
  } catch (error, stackTrace) {
    final code = buildErrorReferenceCode(
      scope: 'LOG',
      error: error,
      stackTrace: stackTrace,
    );
    appLogService.error(
      '应用日志初始化失败 [$code]',
      source: 'startup',
      error: error,
      stackTrace: stackTrace,
    );
  }
  HttpOverrides.global = _StableHttpOverrides();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => TimeProvider()),
        ChangeNotifierProvider(create: (context) => ThemeModeProvider()),
      ],
      child: AppRecoveryBoundary(
        controller: recoveryController,
        child: const TimeManagerApp(),
      ),
    ),
  );
}

Future<void> _startApplication({
  required AppLogService appLogService,
  required AppRecoveryController recoveryController,
}) async {
  try {
    await _initializeAndRunApplication(
      appLogService: appLogService,
      recoveryController: recoveryController,
    );
  } catch (error, stackTrace) {
    _runStartupFailurePage(
      service: appLogService,
      error: error,
      stackTrace: stackTrace,
      retryStartup: () => _startApplication(
        appLogService: appLogService,
        recoveryController: recoveryController,
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appLogService = AppLogService.instance;
  final recoveryController = AppRecoveryController();
  installGlobalLogErrorHandlers(appLogService);
  installSafeErrorWidgetBuilder(
    service: appLogService,
    recoveryController: recoveryController,
  );

  await _startApplication(
    appLogService: appLogService,
    recoveryController: recoveryController,
  );
}

class _RootRouteTracker extends NavigatorObserver {
  Route<dynamic>? _topRoute;

  Route<dynamic>? get topRoute => _topRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _topRoute = route;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _topRoute = previousRoute;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_topRoute == route) _topRoute = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (_topRoute == oldRoute || oldRoute == null) _topRoute = newRoute;
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
  final _RootRouteTracker _rootRouteTracker = _RootRouteTracker();

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
      navigatorObservers: <NavigatorObserver>[_rootRouteTracker],
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
        onEscapeWithContext: (_) {
          final navigator = rootNavigatorKey.currentState;
          final topRoute = _rootRouteTracker.topRoute;
          if (navigator == null ||
              !navigator.canPop() ||
              !isDismissiblePopupRoute(topRoute)) {
            return false;
          }
          // 不以焦点所在路由作为关闭条件：部分弹层不会主动抢焦点，
          // 但只要顶层确实是可关闭 PopupRoute，Esc 就应保持可用。
          navigator.pop();
          return true;
        },
        child: child ?? const SizedBox.shrink(),
      ),
      home: const MainScreen(),
    );
  }
}
