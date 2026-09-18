import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'app_log_service.dart';
import 'reminder_backend.dart';

/// 所有提醒类型共用的插件初始化、时区与点击路由。
///
/// **为什么必须共用**：`FlutterLocalNotificationsPlugin.initialize()` 每次调用都会
/// 覆盖 `onDidReceiveNotificationResponse`。如果写日记提醒和打卡提醒各自初始化一次，
/// 后初始化的那个会把前一个的点击回调顶掉——症状是"点通知没反应"，属于静默失效。
/// 所以整个 App 只初始化一次，点击在这里按 payload 分发给注册过的路由。
class ReminderPlatform {
  const ReminderPlatform._();

  /// 插件初始化时的默认小图标。每条通知还会在 `AndroidNotificationDetails` 里
  /// 各自指定图标，这里只是兜底。
  static const String defaultSmallIcon = 'ic_stat_diary_reminder';

  static const String logSource = 'reminder';

  @visibleForTesting
  static ReminderBackend? backendOverride;

  @visibleForTesting
  static bool? androidPlatformOverride;

  @visibleForTesting
  static Future<String> Function()? timezoneIdentifierOverride;

  static bool get isAndroid => androidPlatformOverride ?? Platform.isAndroid;

  static ReminderBackend get backend =>
      backendOverride ?? AndroidReminderBackend();

  static String? _timezoneName;

  /// 当前时区名，例如 `Asia/Shanghai`。为 null 表示不可用，调用方必须拒绝排程。
  static String? get timezoneName => _timezoneName;

  static bool _initialized = false;
  static Future<bool>? _initializing;
  static bool _coldStartHandled = false;

  static final Map<String, _TapRoute> _routes = <String, _TapRoute>{};
  static String? _pendingPayload;

  @visibleForTesting
  static void resetForTesting() {
    backendOverride = null;
    androidPlatformOverride = null;
    timezoneIdentifierOverride = null;
    _timezoneName = null;
    _initialized = false;
    _initializing = null;
    _coldStartHandled = false;
    _routes.clear();
    _pendingPayload = null;
  }

  /// 幂等初始化插件与时区，返回插件是否初始化成功。
  ///
  /// 失败不抛出：调用方负责把结果反映到自己的状态快照里。
  static Future<bool> ensureInitialized() {
    if (_initialized) return Future<bool>.value(true);
    return _initializing ??= _initialize();
  }

  static Future<bool> _initialize() async {
    if (!isAndroid) {
      _initialized = true;
      return false;
    }
    try {
      await configureTimezone();
      await backend.initialize(
        // 裸资源名：插件内部用 getIdentifier(name, "drawable", pkg) 解析，
        // 加 `@drawable/` 前缀反而会引入不必要的歧义。
        const AndroidInitializationSettings(defaultSmallIcon),
        onResponse: _handleResponse,
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '通知插件初始化失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      _initialized = true;
      return false;
    }
    _initialized = true;
    return true;
  }

  /// 时区。失败时把 [timezoneName] 留空，由调用方拒绝排程——绝不回退 UTC。
  static Future<void> configureTimezone() async {
    tz_data.initializeTimeZones();
    String? identifier;
    try {
      identifier = timezoneIdentifierOverride != null
          ? await timezoneIdentifierOverride!()
          : (await FlutterTimezone.getLocalTimezone()).identifier;
    } catch (_) {
      identifier = null;
    }
    if (identifier == null || identifier.trim().isEmpty) {
      _timezoneName = null;
      return;
    }
    try {
      final location = tz.getLocation(identifier);
      tz.setLocalLocation(location);
      _timezoneName = location.name;
    } catch (_) {
      // 拿到的不一定是 IANA 名称。没有可信时区就不排程，
      // 用缓存或 UTC 假装成功会让提醒在错误的时间响。
      _timezoneName = null;
    }
  }

  /// 注册点击路由。同一个 [key] 重复注册会覆盖，不会堆积。
  ///
  /// 若点击在注册之前就已到达（冷启动早于界面绑定），会在注册瞬间补发。
  static void registerTapHandler(
    String key, {
    required bool Function(String? payload) matches,
    required void Function(String? payload) handler,
  }) {
    _routes[key] = _TapRoute(matches: matches, handler: handler);
    final pending = _pendingPayload;
    if (pending != null && matches(pending)) {
      _pendingPayload = null;
      handler(pending);
    }
  }

  /// 读取冷启动来源并分发。整个进程只执行一次。
  static Future<void> handleColdStartNavigation() async {
    if (!isAndroid || _coldStartHandled) return;
    _coldStartHandled = true;
    await ensureInitialized();
    try {
      final details = await backend.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        final response = details!.notificationResponse;
        if (response != null) _dispatch(response.payload);
      }
    } catch (error, stackTrace) {
      // 只记录，不抛出：冷启动导航失败不应该影响启动
      AppLogService.instance.warning(
        '读取通知启动动作失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static void _handleResponse(NotificationResponse response) {
    _dispatch(response.payload);
  }

  static void _dispatch(String? payload) {
    for (final route in _routes.values) {
      if (route.matches(payload)) {
        route.handler(payload);
        return;
      }
    }
    // 还没有匹配的路由：可能界面尚未绑定，暂存等注册时补发
    _pendingPayload = payload;
  }

  /// 调用系统接口并把失败降级成 null。所有提醒相关的平台调用都该走这里，
  /// 避免个别设备上的异常把整条链路打断。
  static Future<T?> safe<T>(
    Future<T?> Function() action, {
    String source = logSource,
  }) async {
    try {
      return await action();
    } catch (error, stackTrace) {
      AppLogService.instance.warning(
        '提醒调用系统接口失败',
        source: source,
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static Future<bool> safeBool(
    Future<bool?> Function() action, {
    bool fallback = false,
  }) async {
    final value = await safe(action);
    return value ?? fallback;
  }

  /// 下一次触发时刻。留 5 秒余量，避免插件因为时间已过而抛参数错误。
  static tz.TZDateTime nextInstance(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var next =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now.add(const Duration(seconds: 5)))) {
      next =
          tz.TZDateTime(tz.local, now.year, now.month, now.day + 1, hour, minute);
    }
    return next;
  }
}

class _TapRoute {
  const _TapRoute({required this.matches, required this.handler});

  final bool Function(String? payload) matches;
  final void Function(String? payload) handler;
}
