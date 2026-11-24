import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/services/feishu_calendar_api.dart';
import 'package:time_manager/services/feishu_calendar_constants.dart';
import 'package:time_manager/services/feishu_calendar_planner.dart';

http.Response jsonResponse(Object body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

List<TimeSlot> dayWith(Map<int, String> labels) {
  return List.generate(feishuSlotsPerDay, (index) {
    final label = labels[index];
    return TimeSlot(
      hour: index ~/ 6,
      minute10: (index % 6) * 10,
      recorded: label != null,
      label: label,
    );
  });
}

void main() {
  final day = DateTime(2026, 11, 24);
  final dayStartSeconds = DateTime(2026, 11, 24).millisecondsSinceEpoch ~/ 1000;

  FeishuCalendarApi apiWith(
    Future<http.Response> Function(http.Request) handler,
  ) {
    final client = MockClient(handler);
    addTearDown(client.close);
    return FeishuCalendarApi(client: client);
  }

  group('listDayEvents', () {
    test('按天请求并只认本 App 标记的事件', () async {
      http.Request? captured;
      final api = apiWith((request) async {
        captured = request;
        return jsonResponse({
          'code': 0,
          'data': {
            'items': [
              {
                'event_id': 'e1',
                'summary': '写代码',
                'description': FeishuCalendarConfig.eventMarker,
                'start_time': {'timestamp': '${dayStartSeconds + 3600}'},
                'end_time': {'timestamp': '${dayStartSeconds + 7200}'},
              },
              {
                'event_id': 'e2',
                'summary': '别人建的',
                'description': '',
                'start_time': {'timestamp': '${dayStartSeconds + 3600}'},
                'end_time': {'timestamp': '${dayStartSeconds + 7200}'},
              },
            ],
          },
        });
      });

      final result = await api.listDayEvents(
        accessToken: 't',
        calendarId: 'cal',
        day: day,
      );

      expect(result.success, isTrue);
      expect(result.data!.events, hasLength(1));
      expect(result.data!.events.single.eventId, 'e1');
      expect(result.data!.truncated, isFalse);
      expect(captured!.url.queryParameters['start_time'], '$dayStartSeconds');
      expect(
        captured!.url.queryParameters['end_time'],
        '${dayStartSeconds + 86400}',
      );
      expect(captured!.headers['Authorization'], 'Bearer t');
    });

    test('开始时间不在当天的事件被忽略', () async {
      final api = apiWith((request) async {
        return jsonResponse({
          'code': 0,
          'data': {
            'items': [
              {
                'event_id': 'e1',
                'summary': '跨日',
                'description': FeishuCalendarConfig.eventMarker,
                'start_time': {'timestamp': '${dayStartSeconds - 600}'},
                'end_time': {'timestamp': '${dayStartSeconds + 600}'},
              },
            ],
          },
        });
      });

      final result = await api.listDayEvents(
        accessToken: 't',
        calendarId: 'cal',
        day: day,
      );
      expect(result.data!.events, isEmpty);
    });

    test('has_more 视为截断', () async {
      final api = apiWith((request) async {
        return jsonResponse({
          'code': 0,
          'data': {'items': <dynamic>[], 'has_more': true},
        });
      });
      final result = await api.listDayEvents(
        accessToken: 't',
        calendarId: 'cal',
        day: day,
      );
      expect(result.data!.truncated, isTrue);
    });
  });

  group('createEvent', () {
    test('请求体带标记与时区', () async {
      Map<String, dynamic>? body;
      final api = apiWith((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({'code': 0, 'data': <String, dynamic>{}});
      });

      final result = await api.createEvent(
        accessToken: 't',
        calendarId: 'cal',
        body: buildFeishuEventBody(
          mergeSlotsToEvents(dayWith({0: 'A'}), day).single,
          timezone: 'Asia/Shanghai',
        ),
      );

      expect(result.success, isTrue);
      expect(body!['description'], FeishuCalendarConfig.eventMarker);
      expect((body!['start_time'] as Map)['timestamp'], '$dayStartSeconds');
    });
  });

  group('deleteEvent', () {
    test('404 视为已删除', () async {
      final api = apiWith((request) async => http.Response('', 404));
      final result = await api.deleteEvent(
        accessToken: 't',
        calendarId: 'cal',
        eventId: 'e1',
      );
      expect(result.success, isTrue);
    });
  });

  group('错误映射', () {
    test('权限不足给出可执行提示', () async {
      final api = apiWith((request) async {
        return jsonResponse({'code': 99991672, 'msg': 'Access denied.'});
      });
      final result = await api.listDayEvents(
        accessToken: 't',
        calendarId: 'cal',
        day: day,
      );
      expect(result.success, isFalse);
      expect(result.error, contains('calendar:calendar'));
      expect(result.unauthorized, isFalse);
    });

    test('令牌失效标记 unauthorized', () async {
      final api = apiWith((request) async {
        return jsonResponse({'code': 99991663, 'msg': 'invalid token'});
      });
      final result = await api.listDayEvents(
        accessToken: 't',
        calendarId: 'cal',
        day: day,
      );
      expect(result.unauthorized, isTrue);
    });

    test('HTTP 401 标记 unauthorized', () async {
      final api = apiWith((request) async => http.Response('', 401));
      final result = await api.fetchPrimaryCalendarId('t');
      expect(result.unauthorized, isTrue);
    });
  });

  group('fetchPrimaryCalendarId', () {
    test('优先取 primary 类型', () async {
      final api = apiWith((request) async {
        return jsonResponse({
          'code': 0,
          'data': {
            'calendars': [
              {
                'calendar': {'calendar_id': 'other', 'type': 'shared'},
              },
              {
                'calendar': {'calendar_id': 'main', 'type': 'primary'},
              },
            ],
          },
        });
      });
      final result = await api.fetchPrimaryCalendarId('t');
      expect(result.data, 'main');
    });

    test('权限不足（99991679）视为需要重新授权并给出可执行提示', () async {
      final api = apiWith((request) async {
        return jsonResponse({
          'code': 99991679,
          'msg': 'Unauthorized. You do not have permission to perform the '
              'requested operation on the resource. required one of these '
              'privileges: [calendar:calendar:readonly, calendar:calendar:read]',
        });
      });
      final result = await api.fetchPrimaryCalendarId('t');
      expect(result.success, isFalse);
      expect(result.unauthorized, isTrue);
      expect(result.error, contains('重新授权'));
    });
  });

  test('授权 scope 覆盖查主日历需要的读权限', () {
    // 查主日历只认读权限：漏掉 calendar:calendar:read 会让令牌被 99991679 拒绝。
    expect(FeishuCalendarConfig.scopes, contains('calendar:calendar:read'));
    expect(FeishuCalendarConfig.scopes, contains('calendar:calendar'));
    expect(FeishuCalendarConfig.scopes, contains('offline_access'));
  });
}
