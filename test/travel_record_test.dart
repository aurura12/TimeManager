import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/travel_record.dart';

TravelRecord _record({
  required String date,
  required String location,
  required String event,
}) {
  return TravelRecord(
    date: DateTime.parse(date),
    location: location,
    event: event,
  );
}

void main() {
  test('同一天内容相同不算冲突', () {
    final local = TravelRecordsDocument(records: [
      TravelRecord(
        date: DateTime(2026, 9, 14),
        location: '杭州',
        event: '散步',
      ),
    ]);
    final remote = TravelRecordsDocument(records: [
      TravelRecord(
        date: DateTime(2026, 9, 14),
        location: '杭州',
        event: '散步',
      ),
    ]);

    expect(local.conflictingDateKeys(remote), isEmpty);
  });

  test('同一天地点或事件不同会被识别为冲突', () {
    final local = TravelRecordsDocument(records: [
      _record(date: '2026-09-14', location: '杭州', event: '散步'),
    ]);
    final remote = TravelRecordsDocument(records: [
      _record(date: '2026-09-14', location: '上海', event: '出差'),
    ]);

    expect(local.conflictingDateKeys(remote), {'2026-09-14'});
  });

  test('仅一端存在的日期不是同日冲突', () {
    final local = TravelRecordsDocument(records: [
      _record(date: '2026-09-14', location: '杭州', event: '散步'),
    ]);
    final remote = TravelRecordsDocument(records: [
      _record(date: '2026-09-15', location: '上海', event: '出差'),
    ]);

    expect(local.conflictingDateKeys(remote), isEmpty);
  });
}
