import 'dart:convert';

import 'wake_up_record.dart';

/// 每个身份独立的一份起床文档；待上传标记只写本机，不发往远端。
class WakeUpDocument {
  WakeUpDocument({
    Map<String, WakeUpRecord> records = const {},
    Map<String, int> deletedDates = const {},
    this.pendingSync = false,
  })  : records = Map.unmodifiable(records),
        deletedDates = Map.unmodifiable(deletedDates);

  final Map<String, WakeUpRecord> records;
  final Map<String, int> deletedDates;
  final bool pendingSync;

  bool get isEmpty => records.isEmpty && deletedDates.isEmpty;
  bool get hasLegacyRecords => records.values.any((r) => r.updatedAt == 0);

  int get latestRevision => [
        0,
        ...records.values.map((r) => r.updatedAt),
        ...deletedDates.values,
      ].reduce((a, b) => a > b ? a : b);

  WakeUpDocument withPending(bool value) => WakeUpDocument(
        records: records,
        deletedDates: deletedDates,
        pendingSync: value,
      );

  /// 原本仅在本机保存的记录没有修改时间。给它最低版本，避免覆盖远端
  /// 已经有时间戳的新修改，同时把这些旧记录加入首次上传。
  WakeUpDocument migrateLegacyRecords() => WakeUpDocument(
        records: {
          for (final entry in records.entries)
            entry.key: entry.value.updatedAt == 0
                ? entry.value.withUpdatedAt(1)
                : entry.value,
        },
        deletedDates: deletedDates,
        pendingSync: pendingSync || hasLegacyRecords,
      );

  Map<String, dynamic> toJson({bool includeLocalState = false}) => {
        'version': 2,
        'records': [
          for (final key in records.keys.toList()..sort())
            records[key]!.toJson(),
        ],
        'deletedDates': {
          for (final key in deletedDates.keys.toList()..sort())
            key: deletedDates[key],
        },
        if (includeLocalState) 'pendingSync': pendingSync,
      };

  String encode({bool includeLocalState = false}) =>
      jsonEncode(toJson(includeLocalState: includeLocalState));

  bool equivalentTo(WakeUpDocument other) => encode() == other.encode();

  factory WakeUpDocument.decode(String content, {bool allowLegacy = true}) {
    final data = jsonDecode(content);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('起床记录格式无效');
    }
    final version = data['version'];
    final rawRecords = data['records'];
    if ((version != 2 && !(allowLegacy && version == 1)) ||
        rawRecords is! List) {
      throw const FormatException('起床记录版本或格式无效');
    }
    final records = <String, WakeUpRecord>{};
    for (final entry in rawRecords) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('起床记录格式无效');
      }
      final record = WakeUpRecord.fromJson(entry);
      if ((!allowLegacy && record.updatedAt == 0) ||
          records.containsKey(record.dateKey)) {
        throw const FormatException('起床记录缺少修改时间或存在重复日期');
      }
      records[record.dateKey] = record;
    }
    final rawDeleted = data['deletedDates'];
    if (version == 2 && rawDeleted is! Map<String, dynamic>) {
      throw const FormatException('起床记录的删除信息无效');
    }
    final deleted = <String, int>{};
    if (rawDeleted is Map<String, dynamic>) {
      for (final entry in rawDeleted.entries) {
        if (!WakeUpRecord.isValidDateKey(entry.key) ||
            entry.value is! int ||
            entry.value <= 0) {
          throw const FormatException('起床记录的删除信息无效');
        }
        deleted[entry.key] = entry.value as int;
      }
    }
    if (data.containsKey('pendingSync') && data['pendingSync'] is! bool) {
      throw const FormatException('起床记录的待同步状态无效');
    }
    return WakeUpDocument(
      records: records,
      deletedDates: deleted,
      pendingSync: allowLegacy && data['pendingSync'] == true,
    );
  }

  /// 按日期取最新修改。时间戳相同且内容不同时取较早的起床时间，保证
  /// 两端得到同样结果；删除与记录时间相同则删除优先。
  static WakeUpDocument merge(WakeUpDocument local, WakeUpDocument remote) {
    final deleted = {...local.deletedDates};
    for (final entry in remote.deletedDates.entries) {
      if (entry.value > (deleted[entry.key] ?? 0)) {
        deleted[entry.key] = entry.value;
      }
    }
    final records = {...local.records};
    for (final entry in remote.records.entries) {
      final existing = records[entry.key];
      final next = entry.value;
      if (existing == null ||
          next.updatedAt > existing.updatedAt ||
          (next.updatedAt == existing.updatedAt &&
              next.minuteOfDay < existing.minuteOfDay)) {
        records[entry.key] = next;
      }
    }
    records
        .removeWhere((key, record) => (deleted[key] ?? -1) >= record.updatedAt);
    return WakeUpDocument(records: records, deletedDates: deleted);
  }
}
