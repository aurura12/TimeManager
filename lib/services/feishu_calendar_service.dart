import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import '../models/time_slot.dart';

/// 简单的飞书用户模型
class FeishuUser {
  final String name;
  final String? avatarUrl;
  final String openId;

  FeishuUser({required this.name, this.avatarUrl, required this.openId});
}

class FeishuCalendarService {
  static const String _appSignature = "乖乖🥰晶晶"; // 用于识别本应用创建的日程
  static final _logger = Logger();

  // ⚠️ 请前往飞书开放平台 (open.feishu.cn) 获取以下信息
  static const String appId = "cli_a9184dba9578dbde"; // 替换为你的 App ID
  static const String appSecret =
      "z8p9pZzVjQdYumVjZeagGcUaK2s5bi3b"; // 替换为你的 App Secret

  static String? _userAccessToken;
  static String? _primaryCalendarId;
  static FeishuUser? _currentUser;

  static FeishuUser? get currentUser => _currentUser;

  /// 启动本地服务并等待飞书回调 (自动登录)
  /// [onAuthUrlGenerated] 回调用于将生成的授权链接通知给 UI 层
  static Future<FeishuUser?> login(
      {required Function(String) onAuthUrlGenerated}) async {
    HttpServer? server;
    try {
      // 1. 启动本地服务器，监听 3000 端口
      // 注意：需要在飞书开放平台配置重定向 URL 为 http://127.0.0.1:3000/
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 3000);

      // 2. 生成授权 URL
      const redirectUri = "http://127.0.0.1:3000/";
      const authUrl =
          "https://open.feishu.cn/open-apis/authen/v1/index?redirect_uri=$redirectUri&app_id=$appId";

      // 3. 通知 UI 显示链接
      onAuthUrlGenerated(authUrl);

      // 4. 等待浏览器回调
      await for (var request in server) {
        if (request.uri.path == '/' &&
            request.uri.queryParameters.containsKey('code')) {
          final code = request.uri.queryParameters['code']!;

          // 给浏览器返回一个简单的成功页面
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write(
                '<html><body style="text-align:center;margin-top:50px;font-family:sans-serif;">'
                '<h1>登录成功</h1><p>您可以关闭此页面并返回应用。</p>'
                '<script>window.close();</script>'
                '</body></html>');
          await request.response.close();

          // 5. 使用 code 换取 token
          return await _loginWithCode(code);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      }
    } catch (e) {
      _logger.e("飞书自动登录失败: $e");
    } finally {
      await server?.close();
    }
    return null;
  }

  /// 使用授权码换取 Token (内部方法)
  static Future<FeishuUser?> _loginWithCode(String code) async {
    try {
      // A. 获取 App Access Token
      final appTokenUrl = Uri.parse(
          "https://open.feishu.cn/open-apis/auth/v3/app_access_token/internal");
      final appTokenResp = await http.post(appTokenUrl,
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({'app_id': appId, 'app_secret': appSecret}));
      final appToken = jsonDecode(appTokenResp.body)['app_access_token'];

      // B. 获取 User Access Token
      final userTokenUrl = Uri.parse(
          "https://open.feishu.cn/open-apis/authen/v1/oidc/access_token");
      final userTokenResp = await http.post(userTokenUrl,
          headers: {
            'Authorization': 'Bearer $appToken',
            'Content-Type': 'application/json; charset=utf-8'
          },
          body: jsonEncode({'grant_type': 'authorization_code', 'code': code}));
      final tokenData = jsonDecode(userTokenResp.body);
      _userAccessToken = tokenData['data']['access_token'];

      // C. 获取用户信息
      final userInfoUrl =
          Uri.parse("https://open.feishu.cn/open-apis/authen/v1/user_info");
      final userInfoResp = await http.get(userInfoUrl, headers: _authHeaders());
      final userData = jsonDecode(userInfoResp.body)['data'];

      _currentUser = FeishuUser(
        name: userData['name'] ?? "飞书用户",
        openId: userData['open_id'],
        avatarUrl: userData['avatar_url'],
      );

      return _currentUser;
    } catch (e) {
      _logger.e("换取 Token 失败: $e");
      return null;
    }
  }

  static Future<void> logout() async {
    _currentUser = null;
    _userAccessToken = null;
    _primaryCalendarId = null;
  }

  /// 核心逻辑：将 TimeSlots 同步到飞书日历
  static Future<bool> syncSlotsToFeishu(
      List<TimeSlot> slots, DateTime date) async {
    if (_currentUser == null || _userAccessToken == null) return false;

    // 确保获取到了日历 ID
    if (_primaryCalendarId == null) {
      _primaryCalendarId = await _getPrimaryCalendarId();
      if (_primaryCalendarId == null) {
        _logger.e("无法获取有效的日历 ID");
        return false;
      }
    }

    try {
      final startOfDay = DateTime(date.year, date.month, date.day);
      final endOfDay = startOfDay.add(const Duration(days: 1));

      // 1. 获取飞书日历上已有的本应用事件
      // 飞书 API: List events
      // GET /open-apis/calendar/v4/calendars/primary/events
      final listUrl = Uri.parse(
          "https://open.feishu.cn/open-apis/calendar/v4/calendars/$_primaryCalendarId/events"
          "?time_min=${startOfDay.millisecondsSinceEpoch ~/ 1000}"
          "&time_max=${endOfDay.millisecondsSinceEpoch ~/ 1000}");

      final response = await http.get(listUrl, headers: _authHeaders());

      if (response.statusCode != 200) {
        _logger.e("获取飞书日程失败: ${response.body}");
        return false;
      }

      final data = jsonDecode(response.body);
      final List<dynamic> items = data['data']['items'] ?? [];

      // 过滤出本应用创建的日程 (通过 description 判断)
      List<dynamic> remoteEvents =
          items.where((e) => e['description'] == _appSignature).toList();

      // 本地计算出的合并事件
      List<Map<String, dynamic>> localEvents =
          _convertToMergedEvents(slots, date);

      // A. 找出需要删除的
      for (var re in remoteEvents) {
        bool stillExists = localEvents.any((le) => _isSameEvent(le, re));
        if (!stillExists) {
          await _deleteEvent(re['event_id']);
        }
      }

      // B. 找出需要新增的
      for (var le in localEvents) {
        bool alreadyUploaded = remoteEvents.any((re) => _isSameEvent(le, re));
        if (!alreadyUploaded) {
          await _createEvent(le);
        }
      }

      return true;
    } catch (e) {
      _logger.e("同步到飞书失败: $e");
      return false;
    }
  }

  static Future<String?> _getPrimaryCalendarId() async {
    try {
      final url =
          Uri.parse("https://open.feishu.cn/open-apis/calendar/v4/calendars");
      final response = await http.get(url, headers: _authHeaders());

      if (response.statusCode != 200) {
        _logger.e("获取日历列表失败: ${response.body}");
        return null;
      }

      final data = jsonDecode(response.body);
      final List<dynamic> calendars = data['data']['calendar_list'] ?? [];

      // 1. 尝试查找 type 为 primary 的日历
      for (var cal in calendars) {
        if (cal['type'] == 'primary') return cal['calendar_id'];
      }
      // 2. 如果没找到，返回列表中的第一个
      if (calendars.isNotEmpty) return calendars.first['calendar_id'];
    } catch (e) {
      _logger.e("获取主日历ID异常: $e");
    }
    return null;
  }

  static Map<String, String> _authHeaders() {
    return {
      'Authorization': 'Bearer $_userAccessToken',
      'Content-Type': 'application/json; charset=utf-8',
    };
  }

  static Future<void> _deleteEvent(String eventId) async {
    final url = Uri.parse(
        "https://open.feishu.cn/open-apis/calendar/v4/calendars/$_primaryCalendarId/events/$eventId");
    await http.delete(url, headers: _authHeaders());
  }

  static Future<void> _createEvent(Map<String, dynamic> eventData) async {
    final url = Uri.parse(
        "https://open.feishu.cn/open-apis/calendar/v4/calendars/$_primaryCalendarId/events");
    await http.post(url, headers: _authHeaders(), body: jsonEncode(eventData));
  }

  // 比较本地和远程事件是否一致
  static bool _isSameEvent(Map<String, dynamic> local, dynamic remote) {
    // 飞书的时间戳是字符串秒数
    String localStart = local['start_time']['timestamp'];
    String localEnd = local['end_time']['timestamp'];
    String remoteStart = remote['start_time']['timestamp'];
    String remoteEnd = remote['end_time']['timestamp'];

    return local['summary'] == remote['summary'] &&
        localStart == remoteStart &&
        localEnd == remoteEnd;
  }

  // 将 TimeSlots 转换为飞书 API 需要的 JSON 结构
  static List<Map<String, dynamic>> _convertToMergedEvents(
      List<TimeSlot> slots, DateTime date) {
    List<Map<String, dynamic>> merged = [];
    int i = 0;
    while (i < slots.length) {
      if (slots[i].recorded && slots[i].label != null) {
        String label = slots[i].label!;
        int startIdx = i;
        while (
            i < slots.length && slots[i].recorded && slots[i].label == label) {
          i++;
        }
        int endIdx = i;

        DateTime startTime = DateTime(date.year, date.month, date.day,
            startIdx ~/ 6, (startIdx % 6) * 10);
        DateTime endTime = DateTime(
            date.year, date.month, date.day, endIdx ~/ 6, (endIdx % 6) * 10);

        merged.add({
          "summary": label,
          "description": _appSignature,
          "start_time": {
            "timestamp": "${startTime.millisecondsSinceEpoch ~/ 1000}",
            "timezone": "Asia/Shanghai" // 飞书建议指定时区
          },
          "end_time": {
            "timestamp": "${endTime.millisecondsSinceEpoch ~/ 1000}",
            "timezone": "Asia/Shanghai"
          }
        });
      } else {
        i++;
      }
    }
    return merged;
  }
}
