import 'dart:convert';

import 'package:intl/intl.dart';

class TravelRecord {
  final DateTime date;
  final String location;
  final String event;

  const TravelRecord({
    required this.date,
    required this.location,
    required this.event,
  });

  String get dateKey => DateFormat('yyyy-MM-dd').format(date);

  TravelRecord copyWith({DateTime? date, String? location, String? event}) {
    return TravelRecord(
      date: date ?? this.date,
      location: location ?? this.location,
      event: event ?? this.event,
    );
  }

  Map<String, dynamic> toJson() {
    return {'date': dateKey, 'location': location, 'event': event};
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
    );
  }
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
    final next = [...records];
    final idx = next.indexWhere((e) => e.dateKey == record.dateKey);
    if (idx >= 0) {
      next[idx] = record;
    } else {
      next.add(record);
    }
    next.sort((a, b) => b.date.compareTo(a.date));
    final deleted = {...deletedAtByDate}..remove(record.dateKey);
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
    final next = records
        .where(
          (entry) =>
              entry.dateKey != previousDateKey &&
              entry.dateKey != record.dateKey,
        )
        .toList()
      ..add(record);
    next.sort((a, b) => b.date.compareTo(a.date));

    final deleted = {...deletedAtByDate};
    if (previousDateKey != record.dateKey) {
      final timestamp = (deletedAt ?? DateTime.now()).millisecondsSinceEpoch;
      final previousTimestamp = deleted[previousDateKey];
      deleted[previousDateKey] = previousTimestamp == null
          ? timestamp
          : (previousTimestamp > timestamp ? previousTimestamp : timestamp);
    }
    deleted.remove(record.dateKey);
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

  /// 将远端内容应用到本地，但保留本地尚未同步的删除意图。
  ///
  /// 远端旧记录即使仍存在，也不能覆盖本地 tombstone；其它日期仍按现有
  /// 拉取语义以远端为准。
  TravelRecordsDocument mergeRemotePreservingLocalDeletions(
    TravelRecordsDocument remote,
  ) {
    final deleted = <String, int>{...remote.deletedAtByDate};
    for (final entry in deletedAtByDate.entries) {
      final previous = deleted[entry.key];
      deleted[entry.key] =
          previous == null || entry.value > previous ? entry.value : previous;
    }
    final mergedRecords = remote.records
        .where((record) => !deleted.containsKey(record.dateKey))
        .toList();
    return TravelRecordsDocument(
      records: mergedRecords,
      deletedAtByDate: deleted,
    );
  }

  /// 构造本次推送的文档，保留远端已有 tombstone，并让本地删除优先于
  /// 远端仍未删除的旧记录。
  TravelRecordsDocument preparePush(TravelRecordsDocument remote) {
    final deleted = <String, int>{...remote.deletedAtByDate};
    for (final entry in deletedAtByDate.entries) {
      final previous = deleted[entry.key];
      deleted[entry.key] =
          previous == null || entry.value > previous ? entry.value : previous;
    }
    // 本地重新新增的记录代表用户已经撤销了该日期的删除意图。远端可能
    // 仍保留旧 tombstone，不能让它把这条新记录再次过滤掉。
    for (final record in records) {
      if (!deletedAtByDate.containsKey(record.dateKey)) {
        deleted.remove(record.dateKey);
      }
    }
    final pushRecords = records
        .where((record) => !deleted.containsKey(record.dateKey))
        .toList();
    return TravelRecordsDocument(
      records: pushRecords,
      deletedAtByDate: deleted,
    );
  }

  /// 返回两端同一天但内容不同的记录日期。
  ///
  /// 出行记录没有逐条时间戳，同一天的不同地点/事件无法自动判断谁更新，
  /// 因此同步写入前必须把这类日期视为冲突并中止覆盖。
  Set<String> conflictingDateKeys(TravelRecordsDocument other) {
    final conflicts = <String>{};
    for (final local in records) {
      if (other.deletedDateKeys.contains(local.dateKey)) {
        conflicts.add(local.dateKey);
        continue;
      }
      final hasConflict = other.records.any(
        (remote) =>
            remote.dateKey == local.dateKey &&
            (remote.location != local.location || remote.event != local.event),
      );
      if (hasConflict) conflicts.add(local.dateKey);
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

  static int? _timestampFromJson(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String _extractBody(String markdown) {
    final match = RegExp(
      r'^---\n([\s\S]*?)\n---\n?',
      multiLine: false,
    ).firstMatch(markdown);
    if (match == null) return markdown;
    return markdown.substring(match.end);
  }
}
