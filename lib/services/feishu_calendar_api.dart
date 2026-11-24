import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/feishu_calendar_models.dart';
import 'contents_api_common.dart';
import 'feishu_calendar_constants.dart';
import 'feishu_calendar_log.dart';
import 'feishu_calendar_planner.dart';

/// 飞书日历 OpenAPI 的薄封装。
///
/// 统一返回 [FeishuApiResult]，业务错误（code != 0）不抛异常；令牌失效会把
/// [FeishuApiResult.unauthorized] 置真，由调用方刷新后重放一次。
class FeishuCalendarApi {
  FeishuCalendarApi({http.Client? client}) : _client = client;

  final http.Client? _client;

  static const int _pageSize = 1000;

  Future<FeishuApiResult<String>> fetchPrimaryCalendarId(
    String accessToken,
  ) async {
    final result = await _send(
      (client) => client.post(
        Uri.parse(
          '${FeishuCalendarConfig.apiBase}/calendar/v4/calendars/primary',
        ),
        headers: _headers(accessToken),
      ),
    );
    if (!result.success) {
      return FeishuApiResult.failed(
        result.error!,
        unauthorized: result.unauthorized,
      );
    }
    final calendars = result.data?['calendars'];
    if (calendars is List) {
      for (final entry in calendars) {
        final calendar = entry is Map ? entry['calendar'] : null;
        if (calendar is! Map) continue;
        final id = (calendar['calendar_id'] ?? '').toString();
        if (id.isNotEmpty && (calendar['type'] ?? '').toString() == 'primary') {
          return FeishuApiResult.ok(id);
        }
      }
      for (final entry in calendars) {
        final calendar = entry is Map ? entry['calendar'] : null;
        if (calendar is! Map) continue;
        final id = (calendar['calendar_id'] ?? '').toString();
        if (id.isNotEmpty) return FeishuApiResult.ok(id);
      }
    }
    return FeishuApiResult.failed('没有找到飞书主日历');
  }

  Future<FeishuApiResult<FeishuEventPage>> listDayEvents({
    required String accessToken,
    required String calendarId,
    required DateTime day,
  }) async {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final startSeconds = dayStart.millisecondsSinceEpoch ~/ 1000;
    final endSeconds = dayEnd.millisecondsSinceEpoch ~/ 1000;

    final uri = Uri.parse(
      '${FeishuCalendarConfig.apiBase}/calendar/v4/calendars/$calendarId/events',
    ).replace(queryParameters: {
      'start_time': '$startSeconds',
      'end_time': '$endSeconds',
      'page_size': '$_pageSize',
    });

    final result = await _send(
      (client) => client.get(uri, headers: _headers(accessToken)),
    );
    if (!result.success) {
      return FeishuApiResult.failed(
        result.error!,
        unauthorized: result.unauthorized,
      );
    }

    final items = result.data?['items'];
    final events = <FeishuRemoteEvent>[];
    if (items is List) {
      for (final item in items) {
        if (item is! Map) continue;
        final event = parseFeishuRemoteEvent(
          item.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (event == null) continue;
        // 只认开始时间落在当天的，避免跨日时间块在次日被当成孤儿删掉。
        if (event.startSeconds < startSeconds ||
            event.startSeconds >= endSeconds) {
          continue;
        }
        events.add(event);
      }
    }
    final truncated =
        result.data?['has_more'] == true || events.length >= _pageSize;
    if (truncated) {
      feishuLogWarning('飞书日程列表被截断，本次不写操作（${events.length} 条）');
    }
    return FeishuApiResult.ok(
      FeishuEventPage(events: events, truncated: truncated),
    );
  }

  Future<FeishuApiResult<bool>> createEvent({
    required String accessToken,
    required String calendarId,
    required Map<String, dynamic> body,
  }) async {
    final result = await _send(
      (client) => client.post(
        Uri.parse(
          '${FeishuCalendarConfig.apiBase}/calendar/v4/calendars/$calendarId/events',
        ),
        headers: _headers(accessToken),
        body: jsonEncode(body),
      ),
    );
    if (!result.success) {
      return FeishuApiResult.failed(
        result.error!,
        unauthorized: result.unauthorized,
      );
    }
    return FeishuApiResult.ok(true);
  }

  Future<FeishuApiResult<bool>> deleteEvent({
    required String accessToken,
    required String calendarId,
    required String eventId,
  }) async {
    final client = _client ?? http.Client();
    try {
      final response = await requestWithRetry(
        () => client.delete(
          Uri.parse(
            '${FeishuCalendarConfig.apiBase}/calendar/v4/calendars/$calendarId/events/$eventId',
          ),
          headers: _headers(accessToken),
        ),
      );
      if (response.statusCode == 404) {
        // 已经不存在，视为删除成功。
        return FeishuApiResult.ok(true);
      }
      final parsed = _decode(response);
      if (!parsed.success) {
        return FeishuApiResult.failed(
          parsed.error!,
          unauthorized: parsed.unauthorized,
        );
      }
      return FeishuApiResult.ok(true);
    } catch (e, stackTrace) {
      feishuLogError('删除飞书日程失败', error: e, stackTrace: stackTrace);
      return FeishuApiResult.failed('网络错误，请稍后重试');
    } finally {
      if (_client == null) client.close();
    }
  }

  Map<String, String> _headers(String accessToken) => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json; charset=utf-8',
      };

  Future<FeishuApiResult<Map<String, dynamic>>> _send(
    Future<http.Response> Function(http.Client client) request,
  ) async {
    final client = _client ?? http.Client();
    try {
      final response = await requestWithRetry(() => request(client));
      return _decode(response);
    } catch (e, stackTrace) {
      feishuLogError('飞书日历请求失败', error: e, stackTrace: stackTrace);
      return FeishuApiResult.failed('网络错误，请稍后重试');
    } finally {
      if (_client == null) client.close();
    }
  }

  FeishuApiResult<Map<String, dynamic>> _decode(http.Response response) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      json = null;
    }

    if (response.statusCode == 401) {
      return FeishuApiResult.failed('飞书授权已失效', unauthorized: true);
    }
    if (json == null) {
      return FeishuApiResult.failed(
        '飞书返回了无法识别的数据（${response.statusCode}）',
      );
    }

    final code = json['code'];
    if (code != null && code != 0) {
      final errorCode = code.toString();
      return FeishuApiResult.failed(
        _describeError(errorCode, (json['msg'] ?? '').toString()),
        unauthorized: _isTokenError(errorCode),
      );
    }
    final data = json['data'];
    if (data is Map<String, dynamic>) return FeishuApiResult.ok(data);
    return FeishuApiResult.ok(<String, dynamic>{});
  }

  static bool _isTokenError(String code) {
    return code == '99991663' ||
        code == '99991668' ||
        code == '99991677' ||
        code == '99991661' ||
        // 令牌没有接口要求的用户权限（scope 没申请到 / 授权早于权限开通）。
        // 这也是「需要用户重新授权」的一种，归到这里页面才会提示重连。
        code == '99991679';
  }

  static String _describeError(String code, String message) {
    final fallback = message.isEmpty ? '飞书接口返回错误（$code）' : message;
    return switch (code) {
      '99991672' => '飞书应用缺少日历权限，请到开发者后台开通 calendar:calendar 并发布',
      '99991679' => '飞书应用未获得该操作所需的日历用户授权，请确认开发者后台已开通日历权限，然后重新授权',
      '20010' => '当前飞书账号不在应用的可用范围内，请在开发者后台把使用范围加上自己',
      '190006' => 'App ID 或 App Secret 不正确',
      '191004' => '该日历类型不支持写入，请确认用的是主日历',
      '99991663' || '99991668' => '飞书授权已失效，请重新授权',
      _ => fallback,
    };
  }
}
