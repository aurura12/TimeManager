import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:time_manager/services/google_calendar_event_parser.dart';

void main() {
  test('单日全天事件解析为当天零点到次日零点', () {
    final event = calendar.Event(
      id: 'all-day-1',
      summary: '全天安排',
      start: calendar.EventDateTime(date: DateTime(2026, 8, 24)),
      end: calendar.EventDateTime(date: DateTime(2026, 8, 25)),
    );

    final block = calendarEventToBlock(event, DateTime(2026, 8, 24));

    expect(block, isNotNull);
    expect(block!.title, '全天安排');
    expect(block.start, DateTime(2026, 8, 24));
    expect(block.end, DateTime(2026, 8, 25));
    expect(block.eventId, 'all-day-1');
  });

  test('跨多日全天事件在查询日期裁剪为完整一天', () {
    final event = calendar.Event(
      summary: '出差',
      start: calendar.EventDateTime(date: DateTime(2026, 8, 23)),
      end: calendar.EventDateTime(date: DateTime(2026, 8, 26)),
    );

    final block = calendarEventToBlock(event, DateTime(2026, 8, 24));

    expect(block, isNotNull);
    expect(block!.start, DateTime(2026, 8, 24));
    expect(block.end, DateTime(2026, 8, 25));
  });

  test('夏令时切换日仍裁剪到下一自然日零点', () {
    final event = calendar.Event(
      summary: '跨夏令时安排',
      start: calendar.EventDateTime(date: DateTime(2026, 3, 7)),
      end: calendar.EventDateTime(date: DateTime(2026, 3, 10)),
    );

    final block = calendarEventToBlock(event, DateTime(2026, 3, 8));

    expect(block, isNotNull);
    expect(block!.start, DateTime(2026, 3, 8));
    expect(block.end, DateTime(2026, 3, 9));
  });

  test('全天事件的排他结束日期不再生成时间块', () {
    final event = calendar.Event(
      summary: '全天安排',
      start: calendar.EventDateTime(date: DateTime(2026, 8, 24)),
      end: calendar.EventDateTime(date: DateTime(2026, 8, 25)),
    );

    final block = calendarEventToBlock(event, DateTime(2026, 8, 25));

    expect(block, isNull);
  });

  test('普通定时事件仍按查询日期裁剪', () {
    final event = calendar.Event(
      summary: '跨日会议',
      start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 23, 23)),
      end: calendar.EventDateTime(dateTime: DateTime(2026, 8, 24, 1)),
    );

    final block = calendarEventToBlock(event, DateTime(2026, 8, 24));

    expect(block, isNotNull);
    expect(block!.start, DateTime(2026, 8, 24));
    expect(block.end, DateTime(2026, 8, 24, 1));
  });

  test('起止边界类型不一致时忽略事件', () {
    final event = calendar.Event(
      summary: '格式异常',
      start: calendar.EventDateTime(date: DateTime(2026, 8, 24)),
      end: calendar.EventDateTime(dateTime: DateTime(2026, 8, 25)),
    );

    final block = calendarEventToBlock(event, DateTime(2026, 8, 24));

    expect(block, isNull);
  });

  test('空标题全天事件不生成时间块', () {
    final event = calendar.Event(
      summary: '   ',
      start: calendar.EventDateTime(date: DateTime(2026, 8, 24)),
      end: calendar.EventDateTime(date: DateTime(2026, 8, 25)),
    );

    final block = calendarEventToBlock(event, DateTime(2026, 8, 24));

    expect(block, isNull);
  });
}
