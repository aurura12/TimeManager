import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/feishu_calendar_models.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/services/feishu_calendar_constants.dart';
import 'package:time_manager/services/feishu_calendar_planner.dart';

List<TimeSlot> buildDay(Map<int, String> labels) {
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
  group('mergeSlotsToEvents', () {
    final date = DateTime(2026, 11, 24);

    test('连续同标签合并成一个事件', () {
      final slots = buildDay({0: '睡觉', 1: '睡觉', 2: '睡觉'});
      final drafts = mergeSlotsToEvents(slots, date);
      expect(drafts, hasLength(1));
      expect(drafts.single.summary, '睡觉');
      expect(drafts.single.start, DateTime(2026, 11, 24, 0, 0));
      expect(drafts.single.end, DateTime(2026, 11, 24, 0, 30));
    });

    test('中间有空格会拆成两个事件', () {
      final slots = buildDay({0: 'A', 1: 'A', 3: 'A'});
      final drafts = mergeSlotsToEvents(slots, date);
      expect(drafts, hasLength(2));
      expect(drafts[0].end, DateTime(2026, 11, 24, 0, 20));
      expect(drafts[1].start, DateTime(2026, 11, 24, 0, 30));
    });

    test('标签不同不合并', () {
      final slots = buildDay({0: 'A', 1: 'B'});
      expect(mergeSlotsToEvents(slots, date), hasLength(2));
    });

    test('墓碑与外部日历槽位被跳过', () {
      final slots = buildDay({0: 'A', 1: 'A', 2: 'B'});
      slots[1].deletedAt = DateTime(2026, 11, 24);
      slots[2].isFromCalendar = true;
      final drafts = mergeSlotsToEvents(slots, date);
      expect(drafts, hasLength(1));
      expect(drafts.single.summary, 'A');
      expect(drafts.single.end, DateTime(2026, 11, 24, 0, 10));
    });

    test('占满整天时结束于次日零点', () {
      final slots = buildDay({for (var i = 0; i < 144; i++) i: '满'});
      final drafts = mergeSlotsToEvents(slots, date);
      expect(drafts.single.start, DateTime(2026, 11, 24, 0, 0));
      expect(drafts.single.end, DateTime(2026, 11, 25, 0, 0));
    });

    test('空白标签忽略', () {
      final slots = buildDay({0: '   '});
      expect(mergeSlotsToEvents(slots, date), isEmpty);
    });
  });

  group('diffFeishuDayEvents', () {
    FeishuEventDraft draft(String summary, int startSec, int endSec) {
      return FeishuEventDraft(
        summary: summary,
        start: DateTime.fromMillisecondsSinceEpoch(startSec * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(endSec * 1000),
      );
    }

    const remoteA = FeishuRemoteEvent(
      eventId: 'e1',
      summary: 'A',
      startSeconds: 1000,
      endSeconds: 2000,
    );

    test('两端一致时没有任何操作', () {
      final diff = diffFeishuDayEvents(
        local: [draft('A', 1000, 2000)],
        remote: const [remoteA],
        remoteTruncated: false,
      );
      expect(diff.isEmpty, isTrue);
    });

    test('本地有远端没有就创建', () {
      final diff = diffFeishuDayEvents(
        local: [draft('A', 1000, 2000), draft('B', 3000, 4000)],
        remote: const [remoteA],
        remoteTruncated: false,
      );
      expect(diff.toCreate.single.summary, 'B');
      expect(diff.toDelete, isEmpty);
    });

    test('远端有本地没有就删除', () {
      final diff = diffFeishuDayEvents(
        local: const [],
        remote: const [remoteA],
        remoteTruncated: false,
      );
      expect(diff.toCreate, isEmpty);
      expect(diff.toDelete.single.eventId, 'e1');
    });

    test('改名视为一删一建', () {
      final diff = diffFeishuDayEvents(
        local: [draft('A2', 1000, 2000)],
        remote: const [remoteA],
        remoteTruncated: false,
      );
      expect(diff.toCreate.single.summary, 'A2');
      expect(diff.toDelete.single.summary, 'A');
    });

    test('远端被截断时不删也不建', () {
      final diff = diffFeishuDayEvents(
        local: [draft('B', 3000, 4000)],
        remote: const [remoteA],
        remoteTruncated: true,
      );
      expect(diff.isEmpty, isTrue);
    });

    test('重复的同签名事件只保留一个', () {
      final diff = diffFeishuDayEvents(
        local: [draft('A', 1000, 2000)],
        remote: const [remoteA, remoteA],
        remoteTruncated: false,
      );
      expect(diff.toCreate, isEmpty);
      expect(diff.toDelete, hasLength(1));
    });
  });

  group('令牌过期', () {
    test('提前五分钟视为过期', () {
      final now = DateTime(2026, 11, 24, 12);
      final token = FeishuTokenSet(
        accessToken: 't',
        accessExpiresAt: now.add(const Duration(minutes: 4)),
      );
      expect(token.isAccessExpired(now), isTrue);
    });

    test('还早就没过期', () {
      final now = DateTime(2026, 11, 24, 12);
      final token = FeishuTokenSet(
        accessToken: 't',
        accessExpiresAt: now.add(const Duration(minutes: 30)),
      );
      expect(token.isAccessExpired(now), isFalse);
    });

    test('refresh 过期判定', () {
      final now = DateTime(2026, 11, 24, 12);
      final token = FeishuTokenSet(
        accessToken: 't',
        accessExpiresAt: now.add(const Duration(hours: 1)),
        refreshToken: 'r',
        refreshExpiresAt: now.subtract(const Duration(seconds: 1)),
      );
      expect(token.isRefreshExpired(now), isTrue);
    });
  });

  group('授权链接与回调', () {
    test('授权链接带上 PKCE 与固定回调地址', () {
      final uri = buildFeishuAuthorizeUri(
        appId: 'cli_test',
        state: 'state-1',
        codeChallenge: 'challenge-1',
      );
      expect(uri.queryParameters['client_id'], 'cli_test');
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['redirect_uri'],
          FeishuCalendarConfig.redirectUri);
      expect(uri.queryParameters['state'], 'state-1');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['scope'], contains('offline_access'));
    });

    test('PKCE verifier 长度与 challenge 稳定', () {
      final verifier = generateFeishuCodeVerifier(Random(1));
      expect(verifier.length, 64);
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);
      expect(feishuCodeChallenge(verifier), feishuCodeChallenge(verifier));
      expect(feishuCodeChallenge(verifier), isNot(contains('=')));
    });

    test('整条回调 URL 能解析出 code 与 state', () {
      final result = parseFeishuAuthCallback(
        'http://127.0.0.1:17890/feishu/oauth/callback?code=abc&state=s1',
      );
      expect(result.code, 'abc');
      expect(result.state, 's1');
      expect(result.isSuccess, isTrue);
    });

    test('只有 query 片段也能解析', () {
      final result = parseFeishuAuthCallback('code=abc&state=s1');
      expect(result.code, 'abc');
    });

    test('直接粘 code', () {
      final result = parseFeishuAuthCallback('  abc123  ');
      expect(result.code, 'abc123');
      expect(result.isSuccess, isTrue);
    });

    test('拒绝授权有 error 且不算成功', () {
      final result = parseFeishuAuthCallback(
        'http://127.0.0.1/?error=access_denied&error_description=用户拒绝',
      );
      expect(result.error, 'access_denied');
      expect(result.isSuccess, isFalse);
    });
  });

  group('事件体与远端解析', () {
    test('创建请求体带标记、秒级时间戳与时区', () {
      final body = buildFeishuEventBody(
        FeishuEventDraft(
          summary: '写代码',
          start: DateTime(2026, 11, 24, 9),
          end: DateTime(2026, 11, 24, 10, 30),
        ),
        timezone: 'Asia/Shanghai',
      );
      expect(body['description'], FeishuCalendarConfig.eventMarker);
      expect(body['summary'], '写代码');
      final start = body['start_time'] as Map<String, dynamic>;
      expect(start['timestamp'],
          '${DateTime(2026, 11, 24, 9).millisecondsSinceEpoch ~/ 1000}');
      expect(start['timezone'], 'Asia/Shanghai');
      expect(body.containsKey('attendees'), isFalse);
    });

    test('超长标题截断到 200 字', () {
      final body = buildFeishuEventBody(
        FeishuEventDraft(
          summary: 'x' * 300,
          start: DateTime(2026, 11, 24, 9),
          end: DateTime(2026, 11, 24, 10),
        ),
        timezone: 'Asia/Shanghai',
      );
      expect((body['summary'] as String).length, 200);
    });

    test('只认本 App 标记的事件', () {
      final event = parseFeishuRemoteEvent({
        'event_id': 'e1',
        'summary': 'A',
        'description': '别人的日程',
        'start_time': {'timestamp': '1000'},
        'end_time': {'timestamp': '2000'},
      });
      expect(event, isNull);
    });

    test('已取消事件忽略', () {
      final event = parseFeishuRemoteEvent({
        'event_id': 'e1',
        'summary': 'A',
        'description': FeishuCalendarConfig.eventMarker,
        'status': 'cancelled',
        'start_time': {'timestamp': '1000'},
        'end_time': {'timestamp': '2000'},
      });
      expect(event, isNull);
    });

    test('支持 date_time 形式的时间', () {
      final event = parseFeishuRemoteEvent({
        'event_id': 'e1',
        'summary': 'A',
        'description': FeishuCalendarConfig.eventMarker,
        'start_time': {'date_time': '2026-11-24T09:00:00+08:00'},
        'end_time': {'date_time': '2026-11-24T10:00:00+08:00'},
      });
      expect(event, isNotNull);
      expect(event!.endSeconds - event.startSeconds, 3600);
    });
  });
}
