import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:logger/logger.dart';
import '../config/google_sign_in_config.dart';
import '../models/time_slot.dart';
import '../models/calendar_block.dart';

class GoogleCalendarService {
  static const String _appSignature = "乖乖🥰晶晶";
  static final _logger = Logger();
  static const List<String> _scopes = [calendar.CalendarApi.calendarEventsScope];
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  static GoogleSignInAccount? _currentUser;
  static bool _initialized = false;
  static String? _lastLoginError;

  static bool get isConfigured => GoogleSignInConfig.serverClientId.trim().isNotEmpty;
  static String? get lastLoginError => _lastLoginError;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final serverClientId = GoogleSignInConfig.serverClientId.trim();
    if (serverClientId.isEmpty) {
      throw StateError(
        '未配置 Google Web 客户端 ID，请复制 lib/config/google_sign_in_config.example.dart '
        '为 google_sign_in_config.dart 并填写 serverClientId',
      );
    }
    await _googleSignIn.initialize(serverClientId: serverClientId);
    _googleSignIn.authenticationEvents.listen(
      (event) {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          _currentUser = event.user;
        } else if (event is GoogleSignInAuthenticationEventSignOut) {
          _currentUser = null;
        }
      },
      onError: (error, stack) {
        _logger.e('Google 登录状态流错误: $error', stackTrace: stack);
      },
    );
    _initialized = true;
  }

  // 申请日历事件读写权限
  static Future<GoogleSignInAccount?> login() async {
    _lastLoginError = null;
    try {
      await _ensureInitialized();
      final account = await _googleSignIn.authenticate(scopeHint: _scopes);
      _currentUser = account;
      await account.authorizationClient.authorizeScopes(_scopes);
      return account;
    } on GoogleSignInException catch (e) {
      _lastLoginError = e.description ?? e.toString();
      _logger.e("Google 登录失败: $e");
      return null;
    } catch (e) {
      _lastLoginError = e.toString();
      _logger.e("Google 登录失败: $e");
      return null;
    }
  }

  static Future<void> logout() async {
    await _ensureInitialized();
    await _googleSignIn.signOut();
    _currentUser = null;
  }

  // 尝试静默登录（恢复登录状态）
  static Future<void> restoreSignIn() async {
    await _ensureInitialized();
    try {
      final attempt = _googleSignIn.attemptLightweightAuthentication();
      if (attempt != null) {
        _currentUser = await attempt;
      }
    } catch (e) {
      _logger.e("恢复登录失败: $e");
    }
  }

  // 获取用户信息
  static GoogleSignInAccount? get currentUser => _currentUser;

  // 修正：明确返回类型为 calendar.CalendarApi，不再使用 var
  static Future<calendar.CalendarApi?> getCalendarApi() async {
    await _ensureInitialized();
    var account = _currentUser;
    account ??= await login();
    if (account == null) return null;

    final authorization =
        await account.authorizationClient.authorizationForScopes(_scopes) ??
            await account.authorizationClient.authorizeScopes(_scopes);
    final httpClient = authorization.authClient(scopes: _scopes);
    return calendar.CalendarApi(httpClient);
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
    // 如果未登录，直接返回不报错，方便自动同步调用
    if (api == null) return false;

    try {
      // 1. 清理当天的旧数据（防止重复和处理撤销/删除的情况）
      final startOfDay = DateTime(date.year, date.month, date.day);
      final endOfDay = startOfDay.add(const Duration(days: 1));

      // --- 步骤 1: 获取日历上已有的本应用事件 ---
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

      // A. 找出需要删除的：远程有，但本地没有完全匹配的（时间+内容）
      for (var re in remoteEvents) {
        bool stillExists = localEvents.any((le) =>
            le.summary == re.summary &&
            le.start?.dateTime?.toUtc() == re.start?.dateTime?.toUtc() &&
            le.end?.dateTime?.toUtc() == re.end?.dateTime?.toUtc());

        if (!stillExists) {
          await api.events.delete('primary', re.id!);
          // _logger.i("删除过时事件: ${re.summary}");
        }
      }

      // B. 找出需要新增的：本地有，但远程没有完全匹配的
      for (var le in localEvents) {
        bool alreadyUploaded = remoteEvents.any((re) =>
            re.summary == le.summary &&
            re.start?.dateTime?.toUtc() == le.start?.dateTime?.toUtc() &&
            re.end?.dateTime?.toUtc() == le.end?.dateTime?.toUtc());

        if (!alreadyUploaded) {
          await api.events.insert(le, 'primary');
          // _logger.i("新增事件: ${le.summary}");
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
