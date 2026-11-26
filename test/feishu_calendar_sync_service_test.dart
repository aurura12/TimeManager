import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/feishu_calendar_models.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/services/feishu_calendar_api.dart';
import 'package:time_manager/services/feishu_calendar_sync_service.dart';
import 'package:time_manager/services/feishu_oauth_service.dart';

/// 内存里的假飞书日历：只实现同步编排用到的那几个接口。
class _FakeApi extends FeishuCalendarApi {
  final List<FeishuRemoteEvent> events = <FeishuRemoteEvent>[];
  int createCalls = 0;
  int deleteCalls = 0;
  int _nextId = 1;

  /// 为真时每次创建都额外塞一条完全相同的事件，模拟另一台设备同时创建。
  bool duplicateOnCreate = false;

  @override
  Future<FeishuApiResult<String>> fetchPrimaryCalendarId(
    String accessToken,
  ) async =>
      FeishuApiResult.ok('cal_primary');

  @override
  Future<FeishuApiResult<FeishuEventPage>> listDayEvents({
    required String accessToken,
    required String calendarId,
    required DateTime day,
  }) async {
    // 留一点异步间隙，好让并发调用真的有机会交错。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return FeishuApiResult.ok(
      FeishuEventPage(events: List.of(events), truncated: false),
    );
  }

  @override
  Future<FeishuApiResult<bool>> createEvent({
    required String accessToken,
    required String calendarId,
    required Map<String, dynamic> body,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    createCalls++;
    final start = body['start_time'] as Map<String, dynamic>;
    final end = body['end_time'] as Map<String, dynamic>;
    final created = FeishuRemoteEvent(
      eventId: 'e${_nextId++}',
      summary: body['summary'].toString(),
      startSeconds: int.parse(start['timestamp'].toString()),
      endSeconds: int.parse(end['timestamp'].toString()),
    );
    events.add(created);
    if (duplicateOnCreate) {
      events.add(FeishuRemoteEvent(
        eventId: 'e${_nextId++}',
        summary: created.summary,
        startSeconds: created.startSeconds,
        endSeconds: created.endSeconds,
      ));
    }
    return FeishuApiResult.ok(true);
  }

  @override
  Future<FeishuApiResult<bool>> deleteEvent({
    required String accessToken,
    required String calendarId,
    required String eventId,
  }) async {
    deleteCalls++;
    events.removeWhere((event) => event.eventId == eventId);
    return FeishuApiResult.ok(true);
  }
}

class _FakeOAuth extends FeishuOAuthService {
  @override
  Future<FeishuTokenResult> ensureAccessToken(DiaryKind kind) async =>
      FeishuTokenResult.ok(FeishuTokenSet(
        accessToken: 'access',
        accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      ));
}

/// 一天 144 个槽位，从 [startSlot] 起填 [count] 个同标签的记录。
List<TimeSlot> slotsWith(String label, {int startSlot = 0, int count = 6}) {
  return List<TimeSlot>.generate(144, (index) {
    final filled = index >= startSlot && index < startSlot + count;
    return TimeSlot(
      hour: index ~/ 6,
      minute10: index % 6,
      recorded: filled,
      label: filled ? label : null,
    );
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('同一天并发触发两次同步，只会创建一条日程', () async {
    final api = _FakeApi();
    final service = FeishuCalendarSyncService(api: api, oauth: _FakeOAuth());
    final date = DateTime(2026, 11, 24);
    final slots = slotsWith('写代码');

    // 自动推送与手动全量同时命中一天：各自都会先读到「远端还没有」。
    final outcomes = await Future.wait([
      service.syncDay(kind: DiaryKind.g, date: date, slots: slots),
      service.syncDay(kind: DiaryKind.g, date: date, slots: slots),
    ]);

    expect(outcomes.every((outcome) => outcome.success), isTrue);
    expect(api.createCalls, 1);
    expect(api.events.length, 1);
    expect(api.events.single.summary, '写代码');
  });

  test('创建时另一台设备同时建了同一条日程，会被收敛成一条', () async {
    final api = _FakeApi()..duplicateOnCreate = true;
    final service = FeishuCalendarSyncService(api: api, oauth: _FakeOAuth());
    final date = DateTime(2026, 11, 24);

    final outcome = await service.syncDay(
      kind: DiaryKind.g,
      date: date,
      slots: slotsWith('写代码'),
    );

    expect(outcome.success, isTrue);
    expect(api.createCalls, 1);
    expect(api.deleteCalls, 1);
    expect(api.events.length, 1, reason: '并发创建的重复日程必须在同一轮收敛');
  });

  test('串行之后第二次同步看到第一条日程，不会重复删除重建', () async {
    final api = _FakeApi();
    final service = FeishuCalendarSyncService(api: api, oauth: _FakeOAuth());
    final date = DateTime(2026, 11, 24);
    final slots = slotsWith('写代码');

    await service.syncDay(kind: DiaryKind.g, date: date, slots: slots);
    final second = await service.syncDay(
      kind: DiaryKind.g,
      date: date,
      slots: slots,
    );

    expect(second.success, isTrue);
    expect(second.created, 0);
    expect(second.deleted, 0);
    expect(api.events.length, 1);
    expect(api.deleteCalls, 0);
  });
}
