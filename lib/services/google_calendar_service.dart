import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:logger/logger.dart';
import '../models/time_slot.dart';

class GoogleCalendarService {
  static const String _appSignature = "Created by TimeManager";
  static final _logger = Logger();

  // 申请日历事件读写权限
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [calendar.CalendarApi.calendarEventsScope],
  );

  static Future<GoogleSignInAccount?> login() => _googleSignIn.signIn();
  static Future<void> logout() => _googleSignIn.signOut();

  // 尝试静默登录（恢复登录状态）
  static Future<void> restoreSignIn() async {
    try {
      await _googleSignIn.signInSilently();
    } catch (e) {
      _logger.e("恢复登录失败: $e");
    }
  }

  // 获取用户信息
  static GoogleSignInAccount? get currentUser => _googleSignIn.currentUser;

  // 修正：明确返回类型为 calendar.CalendarApi，不再使用 var
  static Future<calendar.CalendarApi?> getCalendarApi() async {
    final httpClient = await _googleSignIn.authenticatedClient();
    if (httpClient == null) return null;
    return calendar.CalendarApi(httpClient);
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

      var existingEvents = await api.events.list(
        'primary',
        timeMin: startOfDay.toUtc(),
        timeMax: endOfDay.toUtc(),
        singleEvents: true,
      );

      if (existingEvents.items != null) {
        for (var e in existingEvents.items!) {
          // 仅删除由本应用创建的事件（通过 description 判断）
          if (e.description == _appSignature) {
            await api.events.delete('primary', e.id!);
          }
        }
      }

      // 2. 插入新数据
      int i = 0;
      while (i < slots.length) {
        if (slots[i].recorded && slots[i].label != null) {
          String currentLabel = slots[i].label!;
          int startIdx = i;

          // 查找连续相同 label 的块
          while (i < slots.length &&
              slots[i].recorded &&
              slots[i].label == currentLabel) {
            i++;
          }
          int endIdx = i; // 不包含 i

          // 计算开始和结束时间
          // 每个索引代表 10 分钟
          DateTime startTime = DateTime(date.year, date.month, date.day,
              startIdx ~/ 6, (startIdx % 6) * 10);
          DateTime endTime = DateTime(
              date.year, date.month, date.day, endIdx ~/ 6, (endIdx % 6) * 10);

          // 构建谷歌日历事件
          var event = calendar.Event(
            summary: currentLabel,
            description: _appSignature, // 添加标记
            start: calendar.EventDateTime(
              dateTime: startTime.toUtc(),
              timeZone: "UTC", // 建议使用 UTC 避免时区混乱
            ),
            end: calendar.EventDateTime(
              dateTime: endTime.toUtc(),
              timeZone: "UTC",
            ),
          );

          // 插入到主日历
          await api.events.insert(event, 'primary');
        } else {
          i++;
        }
      }
      return true;
    } catch (e) {
      _logger.e("同步到 Google Calendar 失败: $e");
      return false;
    }
  }
}
