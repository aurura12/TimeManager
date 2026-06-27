import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:logger/logger.dart';
import '../config/google_sign_in_config.dart';
import '../models/google_calendar_user.dart';
import '../models/time_slot.dart';
import '../models/calendar_block.dart';
import 'google_session_store.dart';
import 'app_user_identity_store.dart';

class GoogleCalendarService {
  static const String _appSignature = "乖乖🥰晶晶";
  static final _logger = Logger();
  static const List<String> _scopes = [calendar.CalendarApi.calendarEventsScope];
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  static GoogleSignInAccount? _currentUser;
  static GoogleCalendarUser? _cachedUser;
  static GoogleCalendarUser? _knownUser;
  static bool _knownUserLoaded = false;
  static bool _initialized = false;
  static Future<void>? _bootstrapFuture;
  static Completer<GoogleSignInAccount?>? _restoreCompleter;
  static String? _lastLoginError;

  static final StreamController<void> _authStateController =
      StreamController<void>.broadcast();

  static bool get isConfigured => GoogleSignInConfig.serverClientId.trim().isNotEmpty;
  static String? get lastLoginError => _lastLoginError;
  static Stream<void> get authStateChanges => _authStateController.stream;

  /// 是否有可用 Google 日历 token（可同步日历）
  static bool get isSignedIn => _currentUser != null || _cachedUser != null;

  /// 是否曾登录过 Google（含网络断开、token 失效但仍记得是谁）
  static bool get hasKnownUser =>
      _currentUser != null || _cachedUser != null || _knownUser != null;

  /// 供 UI / 打卡身份；优先在线会话，否则用本地永久身份
  static GoogleCalendarUser? get sessionUser {
    if (_currentUser != null) {
      return GoogleCalendarUser.fromAccount(_currentUser!);
    }
    return _cachedUser ?? _knownUser;
  }

  /// 日历 API 是否可调用（需要有效 token）
  static bool get canUseCalendarApi => isSignedIn;

  /// 身份已识别，但日历 token 不可用（需重新连接）
  static bool get needsCalendarReconnect => hasKnownUser && !isSignedIn;

  @Deprecated('请使用 isSignedIn / sessionUser')
  static GoogleSignInAccount? get currentUser => _currentUser;

  static void _notifyAuthStateChanged() {
    if (!_authStateController.isClosed) {
      _authStateController.add(null);
    }
  }

  static void _log(String message) {
    _logger.i(message);
    debugPrint('[GoogleCalendar] $message');
  }

  /// 应用启动时调用一次：初始化 SDK 并监听登录状态流（7.x 官方推荐）
  static Future<void> bootstrap() {
    _bootstrapFuture ??= _doBootstrap();
    return _bootstrapFuture!;
  }

  static Future<void> _doBootstrap() async {
    if (_initialized) return;
    if (!isConfigured) {
      _log('未配置 serverClientId，跳过 Google 初始化');
      return;
    }

    final serverClientId = GoogleSignInConfig.serverClientId.trim();
    await _googleSignIn.initialize(serverClientId: serverClientId);
    _googleSignIn.authenticationEvents.listen(
      _handleAuthenticationEvent,
      onError: (error, stack) {
        _logger.e('Google 登录状态流错误: $error', stackTrace: stack);
        _restoreCompleter?.complete(_currentUser);
      },
    );
    _initialized = true;
    _log('Google Sign-In 已初始化');
  }

  static Future<void> _ensureCalendarScopes(GoogleSignInAccount account) async {
    try {
      await account.authorizationClient.authorizationForScopes(_scopes) ??
          await account.authorizationClient.authorizeScopes(_scopes);
    } catch (e) {
      _logger.w('恢复日历授权失败: $e');
    }
  }

  static Future<void> _ensureKnownUserLoaded() async {
    if (_knownUserLoaded) return;
    _knownUser = await AppUserIdentityStore.load();
    if (_knownUser == null) {
      final legacy = await GoogleSessionStore.load();
      if (legacy != null) {
        _knownUser = legacy;
        await AppUserIdentityStore.saveUser(legacy);
        _log('已从旧会话档案迁移用户身份: ${_knownUser!.label}');
      }
    }
    _knownUserLoaded = true;
    if (_knownUser != null) {
      _log('已加载本地用户身份: ${_knownUser!.label}');
    }
  }

  static Future<void> _applySignedInUser(GoogleSignInAccount account) async {
    _currentUser = account;
    final user = GoogleCalendarUser.fromAccount(account);
    _cachedUser = user;
    _knownUser = user;
    _knownUserLoaded = true;
    await GoogleSessionStore.save(account);
    await AppUserIdentityStore.save(account);
    await _ensureCalendarScopes(account);
    _notifyAuthStateChanged();
  }

  static Future<void> _clearAllIdentity() async {
    _currentUser = null;
    _cachedUser = null;
    _knownUser = null;
    _knownUserLoaded = false;
    await GoogleSessionStore.clear();
    await AppUserIdentityStore.clear();
  }

  /// 网络/token 失效时：保留「是谁」，仅降级日历连接
  static Future<void> _degradeToKnownUserOnly() async {
    _currentUser = null;
    _cachedUser = null;
    await _ensureKnownUserLoaded();
    if (_knownUser == null) {
      final profile = await GoogleSessionStore.load();
      if (profile != null) {
        _knownUser = profile;
        await AppUserIdentityStore.saveUser(profile);
      }
    }
    if (_knownUser != null) {
      _log('日历 token 不可用，仍识别为: ${_knownUser!.label}');
    }
    _notifyAuthStateChanged();
  }

  static GoogleSignInAuthorizationClient _authorizationClient() {
    return _currentUser?.authorizationClient ?? _googleSignIn.authorizationClient;
  }

  /// 轻量登录失败时：用本地档案 + authorizationForScopes 尝试恢复 token
  static Future<bool> _tryRestoreFromStoredSession() async {
    await _ensureKnownUserLoaded();
    final profile = await GoogleSessionStore.load();
    if (profile == null && _knownUser == null) {
      _log('无本地登录档案');
      return false;
    }

    final identity = profile ?? _knownUser!;
    _log('尝试用本地档案恢复 token: ${identity.label}');
    try {
      final authorization = await _googleSignIn.authorizationClient
          .authorizationForScopes(_scopes);
      if (authorization == null) {
        _log('authorizationForScopes 返回 null，保留本地身份');
        _knownUser ??= identity;
        await AppUserIdentityStore.saveUser(_knownUser!);
        await _degradeToKnownUserOnly();
        return false;
      }
      _cachedUser = identity;
      _knownUser = identity;
      _log('本地档案 + token 恢复成功');
      _notifyAuthStateChanged();
      return true;
    } catch (e) {
      _log('token 恢复失败，保留本地身份: $e');
      _knownUser ??= identity;
      await AppUserIdentityStore.saveUser(_knownUser!);
      await _degradeToKnownUserOnly();
      return false;
    }
  }

  static Future<void> _handleAuthenticationEvent(
    GoogleSignInAuthenticationEvent event,
  ) async {
    if (event is GoogleSignInAuthenticationEventSignIn) {
      await _applySignedInUser(event.user);
      _log('authenticationEvents: 已登录 ${event.user.email}');
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(event.user);
      }
    } else if (event is GoogleSignInAuthenticationEventSignOut) {
      // 网络等原因可能误触发 SignOut，不清永久身份，仅降级日历连接
      await _degradeToKnownUserOnly();
      _log('authenticationEvents: 日历会话断开（保留本地身份）');
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(null);
      }
    }
  }

  static Future<GoogleSignInAccount?> login() async {
    _lastLoginError = null;
    try {
      await bootstrap();
      final account = await _googleSignIn.authenticate(scopeHint: _scopes);
      await _applySignedInUser(account);
      _log('手动登录成功: ${account.email}');
      return account;
    } on GoogleSignInException catch (e) {
      _lastLoginError = e.description ?? e.toString();
      _logger.e('Google 登录失败: $e');
      return null;
    } catch (e) {
      _lastLoginError = e.toString();
      _logger.e('Google 登录失败: $e');
      return null;
    }
  }

  static Future<void> logout() async {
    await bootstrap();
    await _googleSignIn.signOut();
    await _clearAllIdentity();
    _notifyAuthStateChanged();
    _log('已退出 Google 登录');
  }

  /// 重新连接 Google 日历：先静默恢复，失败则弹出登录
  static Future<bool> reconnectCalendar() async {
    _lastLoginError = null;
    if (!isConfigured) return false;

    await restoreSignIn(background: false);
    if (isSignedIn) return true;

    final account = await login();
    return account != null;
  }

  /// 静默恢复会话。
  /// [background] 为 true 时不阻塞首屏：优先本地档案，轻量登录放后台。
  static Future<GoogleSignInAccount?> restoreSignIn({
    bool background = false,
  }) async {
    if (!isConfigured) return null;
    await bootstrap();
    await _ensureKnownUserLoaded();
    if (_currentUser != null) {
      _log('已有会话: ${_currentUser!.email}');
      return _currentUser;
    }
    if (_cachedUser != null) return _currentUser;

    if (await _tryRestoreFromStoredSession()) {
      return _currentUser;
    }

    if (background) {
      unawaited(_attemptLightweightRestore());
      return _currentUser;
    }

    await _attemptLightweightRestore();
    if (!isSignedIn) {
      await _tryRestoreFromStoredSession();
    }
    return _currentUser;
  }

  static Future<void> _attemptLightweightRestore() async {
    if (!isConfigured || isSignedIn) return;

    _restoreCompleter = Completer<GoogleSignInAccount?>();
    try {
      _log('开始 attemptLightweightAuthentication…');
      final attempt = _googleSignIn.attemptLightweightAuthentication();
      if (attempt != null) {
        final account = await attempt;
        if (account != null) {
          await _applySignedInUser(account);
          _log('轻量登录 Future 成功: ${account.email}');
          return;
        }
        _log('轻量登录 Future 返回 null，等待 authenticationEvents…');
      }

      await _restoreCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _log('轻量登录等待超时');
          return _currentUser;
        },
      );
    } catch (e) {
      _logger.e('轻量登录失败: $e');
      _log('轻量登录异常: $e');
    } finally {
      _restoreCompleter = null;
    }
  }

  static Future<calendar.CalendarApi?> getCalendarApi() async {
    await bootstrap();
    if (!isSignedIn) {
      await restoreSignIn();
    }
    if (!isSignedIn) return null;

    final client = _authorizationClient();
    final authorization = await client.authorizationForScopes(_scopes) ??
        await client.authorizeScopes(_scopes);
    return calendar.CalendarApi(authorization.authClient(scopes: _scopes));
  }

  /// 拉取当天非本 App 创建的 Google 日历事件
  static Future<List<CalendarBlock>?> fetchExternalEvents(DateTime date) async {
    final api = await getCalendarApi();
    if (api == null) return null;

    try {
      final startOfDay = DateTime(date.year, date.month, date.day);
      final endOfDay = startOfDay.add(const Duration(days: 1));

      final response = await api.events.list(
        'primary',
        timeMin: startOfDay.toUtc(),
        timeMax: endOfDay.toUtc(),
        singleEvents: true,
      );

      final items = response.items ?? [];
      final blocks = <CalendarBlock>[];

      for (final event in items) {
        if (event.description == _appSignature) continue;
        final block = _eventToBlock(event, date);
        if (block != null) blocks.add(block);
      }
      return blocks;
    } catch (e) {
      _logger.e("从 Google Calendar 拉取失败: $e");
      return null;
    }
  }

  static CalendarBlock? _eventToBlock(calendar.Event event, DateTime date) {
    final startDt = event.start?.dateTime;
    final endDt = event.end?.dateTime;
    if (startDt == null || endDt == null) return null;

    final title = event.summary?.trim();
    if (title == null || title.isEmpty) return null;

    final localStart = startDt.toLocal();
    final localEnd = endDt.toLocal();
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    if (!localEnd.isAfter(dayStart) || !localStart.isBefore(dayEnd)) {
      return null;
    }

    final clippedStart =
        localStart.isBefore(dayStart) ? dayStart : localStart;
    final clippedEnd = localEnd.isAfter(dayEnd) ? dayEnd : localEnd;
    if (!clippedEnd.isAfter(clippedStart)) return null;

    return CalendarBlock(
      title: title,
      start: clippedStart,
      end: clippedEnd,
      eventId: event.id,
    );
  }

  /// 删除 Google 日历中的外部事件（非本 App 创建）
  static Future<bool> deleteExternalEvent(String eventId) async {
    final api = await getCalendarApi();
    if (api == null) return false;

    try {
      final event = await api.events.get('primary', eventId);
      if (event.description == _appSignature) {
        _logger.w("拒绝删除本 App 创建的日历事件: $eventId");
        return false;
      }
      await api.events.delete('primary', eventId);
      return true;
    } catch (e) {
      _logger.e("删除 Google 日历事件失败: $e");
      return false;
    }
  }

  /// 核心逻辑：将 TimeSlots 合并为 Google Calendar 事件并同步
  static Future<bool> syncSlotsToGoogle(
      List<TimeSlot> slots, DateTime date) async {
    final api = await getCalendarApi();
    if (api == null) return false;

    try {
      final startOfDay = DateTime(date.year, date.month, date.day);
      final endOfDay = startOfDay.add(const Duration(days: 1));

      var existingEventsResponse = await api.events.list(
        'primary',
        timeMin: startOfDay.toUtc(),
        timeMax: endOfDay.toUtc(),
        singleEvents: true,
      );
      List<calendar.Event> remoteEvents = existingEventsResponse.items
              ?.where((e) => e.description == _appSignature)
              .toList() ??
          [];
      List<calendar.Event> localEvents = _convertToMergedEvents(slots, date);

      for (var re in remoteEvents) {
        bool stillExists = localEvents.any((le) =>
            le.summary == re.summary &&
            le.start?.dateTime?.toUtc() == re.start?.dateTime?.toUtc() &&
            le.end?.dateTime?.toUtc() == re.end?.dateTime?.toUtc());

        if (!stillExists) {
          await api.events.delete('primary', re.id!);
        }
      }

      for (var le in localEvents) {
        bool alreadyUploaded = remoteEvents.any((re) =>
            re.summary == le.summary &&
            re.start?.dateTime?.toUtc() == le.start?.dateTime?.toUtc() &&
            re.end?.dateTime?.toUtc() == le.end?.dateTime?.toUtc());

        if (!alreadyUploaded) {
          await api.events.insert(le, 'primary');
        }
      }
      return true;
    } catch (e) {
      _logger.e("同步到 Google Calendar 失败: $e");
      return false;
    }
  }

  static List<calendar.Event> _convertToMergedEvents(
      List<TimeSlot> slots, DateTime date) {
    List<calendar.Event> merged = [];
    int i = 0;
    while (i < slots.length) {
      if (slots[i].recorded &&
          !slots[i].isFromCalendar &&
          slots[i].label != null) {
        String label = slots[i].label!;
        int startIdx = i;
        while (i < slots.length &&
            slots[i].recorded &&
            !slots[i].isFromCalendar &&
            slots[i].label == label) {
          i++;
        }
        int endIdx = i;

        DateTime startTime = DateTime(date.year, date.month, date.day,
            startIdx ~/ 6, (startIdx % 6) * 10);
        DateTime endTime = DateTime(
            date.year, date.month, date.day, endIdx ~/ 6, (endIdx % 6) * 10);

        merged.add(calendar.Event(
          summary: label,
          description: _appSignature,
          start: calendar.EventDateTime(
              dateTime: startTime.toUtc(), timeZone: "UTC"),
          end: calendar.EventDateTime(
              dateTime: endTime.toUtc(), timeZone: "UTC"),
        ));
      } else {
        i++;
      }
    }
    return merged;
  }
}
