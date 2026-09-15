import 'dart:convert';

import 'package:intl/intl.dart';

class TravelRecord {
  final DateTime date;
  final String location;
  final String event;

  /// 记录最后一次本地写入的版本时间戳（毫秒）。
  ///
  /// 旧版出行记录没有该字段，使用 0 表示版本未知。未知版本不能
  /// 自动复活 tombstone，避免把一条无法判断新旧的旧记录误当成新记录。
  final int updatedAt;

  const TravelRecord({
    required this.date,
    required this.location,
    required this.event,
    this.updatedAt = 0,
  });

  String get dateKey => DateFormat('yyyy-MM-dd').format(date);

  TravelRecord copyWith({
    DateTime? date,
    String? location,
    String? event,
    int? updatedAt,
  }) {
    return TravelRecord(
      date: date ?? this.date,
      location: location ?? this.location,
      event: event ?? this.event,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'date': dateKey,
      'location': location,
      'event': event,
    };
    if (updatedAt > 0) json['updated_at'] = updatedAt;
    return json;
  }

  factory TravelRecord.fromJson(Map<String, dynamic> json) {
    final dateText = json['date']?.toString() ?? '';
    final parsed = DateTime.tryParse(dateText);
    if (parsed == null) {
      throw const FormatException('记录 date 字段无效');
    }
    return TravelRecord(
      date: DateTime(parsed.year, parsed.month, parsed.day),
      location: json['location']?.toString() ?? '',
      event: json['event']?.toString() ?? '',
      updatedAt:
          _timestampFromJson(json['updated_at'] ?? json['updatedAt']) ?? 0,
    );
  }
}

int? _timestampFromJson(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

class TravelRecordsDocument {
  static const String filePath = 'travel_records.md';

  final List<TravelRecord> records;

  /// 已删除日期的 tombstone，防止离线删除在下一次拉取时被远端旧记录复活。
  ///
  /// key 使用 yyyy-MM-dd，value 是删除发生时的毫秒时间戳。tombstone
  /// 不自动清理：只要旧副本仍可能被拉取，删除意图就必须继续存在。
  final Map<String, int> deletedAtByDate;

  const TravelRecordsDocument({
    required this.records,
    this.deletedAtByDate = const {},
  });

  TravelRecordsDocument upsert(TravelRecord record) {
    final nextRecord = _recordAfterTombstone(
      record,
      deletedAtByDate[record.dateKey],
    );
    final next = [...records];
    final idx = next.indexWhere((e) => e.dateKey == nextRecord.dateKey);
    if (idx >= 0) {
      next[idx] = nextRecord;
    } else {
      next.add(nextRecord);
    }
    next.sort((a, b) => b.date.compareTo(a.date));
    final deleted = {...deletedAtByDate}..remove(nextRecord.dateKey);
    return TravelRecordsDocument(records: next, deletedAtByDate: deleted);
  }

  /// 替换一条记录的日期，同时把旧日期标记为删除。
  ///
  /// 旧日期的 tombstone 会随文档同步到远端，因此日期修改不会把旧日期
  /// 留在远端，也不会在离线期间被下一次拉取恢复。
  TravelRecordsDocument replaceDate({
    required String previousDateKey,
    required TravelRecord record,
    DateTime? deletedAt,
  }) {
    final nextRecord = _recordAfterTombstone(
      record,
      deletedAtByDate[record.dateKey],
    );
    final next = records
        .where(
          (entry) =>
              entry.dateKey != previousDateKey &&
              entry.dateKey != nextRecord.dateKey,
        )
        .toList()
      ..add(nextRecord);
    next.sort((a, b) => b.date.compareTo(a.date));

    final deleted = {...deletedAtByDate};
    if (previousDateKey != nextRecord.dateKey) {
      final timestamp = (deletedAt ?? DateTime.now()).millisecondsSinceEpoch;
      final previousTimestamp = deleted[previousDateKey];
      deleted[previousDateKey] = previousTimestamp == null
          ? timestamp
          : (previousTimestamp > timestamp ? previousTimestamp : timestamp);
    }
    deleted.remove(nextRecord.dateKey);
    return TravelRecordsDocument(records: next, deletedAtByDate: deleted);
  }

  /// 删除指定日期的记录并留下 tombstone。
  TravelRecordsDocument deleteByDate(
    DateTime date, {
    DateTime? deletedAt,
  }) {
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final next = records.where((entry) => entry.dateKey != dateKey).toList();
    final timestamp = (deletedAt ?? DateTime.now()).millisecondsSinceEpoch;
    final deleted = {...deletedAtByDate};
    final previousTimestamp = deleted[dateKey];
    deleted[dateKey] = previousTimestamp == null
        ? timestamp
        : (previousTimestamp > timestamp ? previousTimestamp : timestamp);
    return TravelRecordsDocument(records: next, deletedAtByDate: deleted);
  }

  Set<String> get recordDateKeys => records.map((e) => e.dateKey).toSet();

  Set<String> get deletedDateKeys => deletedAtByDate.keys.toSet();

  /// 将远端内容应用到本地，但按版本保留尚未解决的删除意图。
  ///
  /// 远端旧记录不能覆盖本地 tombstone；严格更新的 live record 可以
  /// 明确撤销旧 tombstone。其它日期仍按现有拉取语义以远端为准。
  TravelRecordsDocument mergeRemotePreservingLocalDeletions(
    TravelRecordsDocument remote,
  ) {
    final localRecords = _recordsByDate(records);
    final remoteRecords = _recordsByDate(remote.records);
    final mergedRecords = <String, TravelRecord>{...remoteRecords};
    final deleted = _mergedTombstones(remote);
    final allDateKeys = <String>{
      ...localRecords.keys,
      ...remoteRecords.keys,
      ...deletedAtByDate.keys,
      ...remote.deletedAtByDate.keys,
    };

    for (final dateKey in allDateKeys) {
      final localRecord = localRecords[dateKey];
      final remoteRecord = remoteRecords[dateKey];
      final deletionAt = _maxTimestamp(
        deletedAtByDate[dateKey],
        remote.deletedAtByDate[dateKey],
      );

      if (deletionAt == null) continue;

      // 只有严格更新的 live record 才能自动复活 tombstone。相等或
      // 缺少版本的记录保持删除状态，并由 UI 的冲突提示交给用户确认。
      final liveRecord = localRecord ?? remoteRecord;
      if (liveRecord != null &&
          _recordIsNewerThanTombstone(liveRecord, deletionAt)) {
        mergedRecords[dateKey] = liveRecord;
        deleted.remove(dateKey);
      } else {
        mergedRecords.remove(dateKey);
        deleted[dateKey] = deletionAt;
      }
    }

    final sortedRecords = mergedRecords.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return TravelRecordsDocument(
      records: sortedRecords,
      deletedAtByDate: deleted,
    );
  }

  /// 构造本次推送的文档，按 live record 与 tombstone 的版本合并两端状态。
  TravelRecordsDocument preparePush(TravelRecordsDocument remote) {
    final localRecords = _recordsByDate(records);
    final remoteRecords = _recordsByDate(remote.records);
    final pushRecordsByDate = <String, TravelRecord>{};
    final deleted = _mergedTombstones(remote);
    final allDateKeys = <String>{
      ...localRecords.keys,
      ...remoteRecords.keys,
      ...deletedAtByDate.keys,
      ...remote.deletedAtByDate.keys,
    };

    for (final dateKey in allDateKeys) {
      final localRecord = localRecords[dateKey];
      final remoteRecord = remoteRecords[dateKey];
      final deletionAt = _maxTimestamp(
        deletedAtByDate[dateKey],
        remote.deletedAtByDate[dateKey],
      );

      if (localRecord != null) {
        if (deletionAt == null ||
            _recordIsNewerThanTombstone(localRecord, deletionAt)) {
          // 本地重新新增的记录只有在版本严格晚于删除时才撤销远端
          // tombstone；否则保留 tombstone，等待 UI 的冲突确认。
          pushRecordsByDate[dateKey] = localRecord;
          deleted.remove(dateKey);
        } else {
          deleted[dateKey] = deletionAt;
        }
        continue;
      }

      // 本地删除与远端较新的重新记录也按版本保留 live record，避免
      // preparePush 在被单独调用时静默删除远端的新内容。
      if (remoteRecord != null &&
          deletedAtByDate[dateKey] != null &&
          _recordIsNewerThanTombstone(remoteRecord, deletionAt!)) {
        pushRecordsByDate[dateKey] = remoteRecord;
        deleted.remove(dateKey);
      }
    }

    final pushRecords = pushRecordsByDate.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return TravelRecordsDocument(
      records: pushRecords,
      deletedAtByDate: deleted,
    );
  }

  /// 返回两端无法自动解决的冲突日期。
  ///
  /// 同一天的 live 记录内容不同仍然需要用户确认；live/tombstone 则按
  /// 记录版本与删除版本判断，只有严格更新的本地重新记录可以自动复活。
  Set<String> conflictingDateKeys(TravelRecordsDocument other) {
    final conflicts = tombstoneConflictDateKeys(other);
    for (final local in records) {
      if (other.deletedDateKeys.contains(local.dateKey)) continue;
      final hasConflict = other.records.any(
        (remote) =>
            remote.dateKey == local.dateKey &&
            (remote.location != local.location || remote.event != local.event),
      );
      if (hasConflict) conflicts.add(local.dateKey);
    }
    return conflicts;
  }

  /// 返回无法仅凭版本自动解决的 live/tombstone 冲突日期。
  ///
  /// 本地记录严格晚于远端 tombstone 时，视为用户明确撤销删除，可以
  /// 自动复活；否则不猜测用户意图，由 UI 阻止覆盖并让用户确认。
  Set<String> tombstoneConflictDateKeys(TravelRecordsDocument other) {
    final conflicts = <String>{};
    for (final local in records) {
      final remoteDeletedAt = other.deletedAtByDate[local.dateKey];
      if (remoteDeletedAt != null &&
          !_recordIsNewerThanTombstone(local, remoteDeletedAt)) {
        conflicts.add(local.dateKey);
      }
    }
    for (final remote in other.records) {
      final localDeletedAt = deletedAtByDate[remote.dateKey];
      if (localDeletedAt != null &&
          _recordIsNewerThanTombstone(remote, localDeletedAt)) {
        conflicts.add(remote.dateKey);
      }
    }
    return conflicts;
  }

  String toMarkdown() {
    final payload = records.map((e) => e.toJson()).toList();
    final Object markdownPayload;
    if (deletedAtByDate.isEmpty) {
      // 保持旧版数组格式，避免无删除记录的现有文件发生无意义迁移。
      markdownPayload = payload;
    } else {
      final deleted = <String, int>{};
      for (final key in deletedAtByDate.keys.toList()..sort()) {
        deleted[key] = deletedAtByDate[key]!;
      }
      markdownPayload = {
        'version': 2,
        'records': payload,
        'deleted_dates': deleted,
      };
    }
    final body = const JsonEncoder.withIndent('  ').convert(markdownPayload);
    final now = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    return '---\n'
        'title: 出行记录\n'
        'updated_at: $now\n'
        '---\n'
        '$body\n';
  }

  static TravelRecordsDocument fromMarkdown(String markdown) {
    final body = _extractBody(markdown).trim();
    if (body.isEmpty) {
      return const TravelRecordsDocument(records: []);
    }
    final decoded = json.decode(body);
    final List<dynamic> rawRecords;
    final deletedAtByDate = <String, int>{};
    if (decoded is List) {
      // v1 格式：正文直接是记录数组。
      rawRecords = decoded;
    } else if (decoded is Map) {
      final raw = decoded['records'];
      if (raw is! List) {
        throw const FormatException('出行记录 records 字段必须是 JSON 数组');
      }
      rawRecords = raw;
      final rawDeleted = decoded['deleted_dates'];
      if (rawDeleted is Map) {
        for (final entry in rawDeleted.entries) {
          final dateKey = _canonicalDateKey(entry.key?.toString());
          final timestamp = _timestampFromJson(entry.value);
          if (dateKey != null && timestamp != null && timestamp > 0) {
            deletedAtByDate[dateKey] = timestamp;
          }
        }
      } else if (rawDeleted is List) {
        // 允许早期开发版本只保存删除日期列表，迁移时使用当前时间。
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final item in rawDeleted) {
          final dateKey = _canonicalDateKey(item?.toString());
          if (dateKey != null) deletedAtByDate[dateKey] = now;
        }
      }
    } else {
      throw const FormatException('出行记录正文必须是 JSON 数组或文档对象');
    }
    final records = <TravelRecord>[];
    for (final item in rawRecords) {
      if (item is! Map) continue;
      final map = item.map((key, value) => MapEntry(key.toString(), value));
      records.add(TravelRecord.fromJson(map));
    }
    records.sort((a, b) => b.date.compareTo(a.date));
    return TravelRecordsDocument(
      records: records,
      deletedAtByDate: deletedAtByDate,
    );
  }

  static String? _canonicalDateKey(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(value.trim());
    if (parsed == null) return null;
    return DateFormat('yyyy-MM-dd').format(parsed);
  }

  static String _extractBody(String markdown) {
    final match = RegExp(
      r'^---\n([\s\S]*?)\n---\n?',
      multiLine: false,
    ).firstMatch(markdown);
    if (match == null) return markdown;
    return markdown.substring(match.end);
  }

  static TravelRecord _recordAfterTombstone(
    TravelRecord record,
    int? deletedAt,
  ) {
    if (deletedAt != null && record.updatedAt <= deletedAt) {
      return record.copyWith(updatedAt: deletedAt + 1);
    }
    if (record.updatedAt > 0) return record;
    // upsert/replaceDate 都代表一次本地写入。即使调用方没有显式传版本，
    // 也要留下可用于跨设备 tombstone 仲裁的版本号。
    return record.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static bool _recordIsNewerThanTombstone(
    TravelRecord record,
    int deletedAt,
  ) {
    return record.updatedAt > 0 && record.updatedAt > deletedAt;
  }

  Map<String, TravelRecord> _recordsByDate(Iterable<TravelRecord> source) {
    final result = <String, TravelRecord>{};
    for (final record in source) {
      final existing = result[record.dateKey];
      if (existing == null || record.updatedAt > existing.updatedAt) {
        result[record.dateKey] = record;
      }
    }
    return result;
  }

  Map<String, int> _mergedTombstones(TravelRecordsDocument remote) {
    final deleted = <String, int>{...remote.deletedAtByDate};
    for (final entry in deletedAtByDate.entries) {
      final previous = deleted[entry.key];
      deleted[entry.key] =
          previous == null || entry.value > previous ? entry.value : previous;
    }
    return deleted;
  }

  static int? _maxTimestamp(int? first, int? second) {
    if (first == null) return second;
    if (second == null) return first;
    return first >= second ? first : second;
  }
}
