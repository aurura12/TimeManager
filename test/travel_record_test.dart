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

  test('编辑日期会移除旧日期并为旧日期写入 tombstone', () {
    final local = TravelRecordsDocument(records: [
      _record(date: '2026-09-14', location: '杭州', event: '散步'),
    ]);

    final moved = local.replaceDate(
      previousDateKey: '2026-09-14',
      record: _record(date: '2026-09-15', location: '上海', event: '出差'),
      deletedAt: DateTime.fromMillisecondsSinceEpoch(100),
    );

    expect(moved.recordDateKeys, {'2026-09-15'});
    expect(moved.deletedAtByDate, {'2026-09-14': 100});
  });

  test('目标日期已有不同记录时会被冲突检测识别', () {
    final existing = TravelRecordsDocument(records: [
      _record(date: '2026-09-15', location: '杭州', event: '散步'),
    ]);
    final replacement = TravelRecordsDocument(records: [
      _record(date: '2026-09-15', location: '上海', event: '出差'),
    ]);

    expect(existing.conflictingDateKeys(replacement), {'2026-09-15'});
  });

  test('删除后重新写入同一天会清除 tombstone', () {
    final deleted = TravelRecordsDocument(records: [
      _record(date: '2026-09-14', location: '杭州', event: '散步'),
    ]).deleteByDate(
      DateTime(2026, 9, 14),
      deletedAt: DateTime.fromMillisecondsSinceEpoch(100),
    );

    final restored = deleted.upsert(
      _record(date: '2026-09-14', location: '上海', event: '出差'),
    );

    expect(restored.recordDateKeys, {'2026-09-14'});
    expect(restored.deletedAtByDate, isEmpty);
  });

  test('旧版数组格式仍可读取，含 tombstone 的文档可 round-trip', () {
    final legacy = TravelRecordsDocument.fromMarkdown('''
---
title: 出行记录
---
[
  {"date":"2026-09-14","location":"杭州","event":"散步"}
]
''');
    expect(legacy.recordDateKeys, {'2026-09-14'});
    expect(legacy.deletedAtByDate, isEmpty);

    final withTombstone = legacy.deleteByDate(
      DateTime(2026, 9, 14),
      deletedAt: DateTime.fromMillisecondsSinceEpoch(100),
    );
    final parsed = TravelRecordsDocument.fromMarkdown(
      withTombstone.toMarkdown(),
    );

    expect(parsed.records, isEmpty);
    expect(parsed.deletedAtByDate, {'2026-09-14': 100});
  });

  test('远端失败后重新拉取不会用旧记录复活本地删除', () {
    final remoteBeforeDelete = TravelRecordsDocument(records: [
      _record(date: '2026-09-14', location: '杭州', event: '散步'),
      _record(date: '2026-09-15', location: '上海', event: '出差'),
    ]);
    final localAfterOfflineDelete = remoteBeforeDelete.deleteByDate(
      DateTime(2026, 9, 14),
      deletedAt: DateTime.fromMillisecondsSinceEpoch(100),
    );

    // 模拟首次推送失败：本地草稿必须仍保留删除意图。
    expect(localAfterOfflineDelete.recordDateKeys, {'2026-09-15'});
    expect(localAfterOfflineDelete.deletedAtByDate, {'2026-09-14': 100});

    // 重新拉取时远端仍是旧副本，删除日期不能复活；其它远端记录正常保留。
    final afterRepull = localAfterOfflineDelete
        .mergeRemotePreservingLocalDeletions(remoteBeforeDelete);
    expect(afterRepull.recordDateKeys, {'2026-09-15'});
    expect(afterRepull.deletedAtByDate, {'2026-09-14': 100});

    // 下一次重试推送仍会携带 tombstone，直到远端真正删除该日期。
    final retryPayload =
        localAfterOfflineDelete.preparePush(remoteBeforeDelete);
    expect(retryPayload.recordDateKeys, {'2026-09-15'});
    expect(retryPayload.deletedAtByDate, {'2026-09-14': 100});
  });

  test('远端 tombstone 会在推送准备阶段保留，避免删除意图丢失', () {
    final local = TravelRecordsDocument(records: [
      _record(date: '2026-09-15', location: '上海', event: '出差'),
    ]);
    final remote = TravelRecordsDocument(
      records: const [],
      deletedAtByDate: const {'2026-09-14': 100},
    );

    final outgoing = local.preparePush(remote);

    expect(outgoing.recordDateKeys, {'2026-09-15'});
    expect(outgoing.deletedAtByDate, {'2026-09-14': 100});
  });

  test('本地重新新增日期会覆盖远端旧 tombstone', () {
    final local = TravelRecordsDocument(records: [
      _record(date: '2026-09-14', location: '上海', event: '重新出发'),
    ]);
    final remote = TravelRecordsDocument(
      records: const [],
      deletedAtByDate: const {'2026-09-14': 100},
    );

    final outgoing = local.preparePush(remote);

    expect(outgoing.recordDateKeys, {'2026-09-14'});
    expect(outgoing.deletedAtByDate, isEmpty);
  });
}
