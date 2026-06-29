import 'dart:convert';

import 'package:intl/intl.dart';

import 'check_in_goal.dart';
import 'check_in_record.dart';
import 'known_google_users.dart';

/// GitHub 上的打卡数据文档（`check_in_data.md`）
class CheckInDocument {
  static const String filePath = 'check_in_data.md';
  static const String imagesDir = 'images';

  final List<CheckInGoal> goals;
  final List<CheckInRecord> records;

  const CheckInDocument({
    required this.goals,
    required this.records,
  });

  static const empty = CheckInDocument(goals: [], records: []);

  /// 将扁平记录挂到各目标上，供 UI 使用
  List<CheckInGoal> goalsWithRecords() {
    return goals.map((goal) {
      final goalRecords = records
          .where((r) => r.goalId == goal.id)
          .toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return goal.copyWith(records: goalRecords);
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  CheckInDocument upsertGoal(CheckInGoal goal) {
    final meta = goal.withoutRecords();
    final nextGoals = [...goals.where((g) => g.id != meta.id), meta];
    return CheckInDocument(goals: nextGoals, records: records);
  }

  CheckInDocument upsertRecord(CheckInRecord record) {
    final nextRecords = [...records.where((r) => r.id != record.id), record]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return CheckInDocument(goals: goals, records: nextRecords);
  }

  CheckInDocument removeRecord(String recordId) {
    final nextRecords = records.where((r) => r.id != recordId).toList();
    return CheckInDocument(goals: goals, records: nextRecords);
  }

  /// 删除目标；默认同时删除该目标下的所有打卡记录
  CheckInDocument removeGoal(String goalId, {bool removeRecords = true}) {
    final nextGoals = goals.where((g) => g.id != goalId).toList();
    final nextRecords = removeRecords
        ? records.where((r) => r.goalId != goalId).toList()
        : records;
    return CheckInDocument(goals: nextGoals, records: nextRecords);
  }

  /// 合并本地与远端（按 id 去重，同 id 保留较新的记录）
  static CheckInDocument merge(CheckInDocument local, CheckInDocument remote) {
    final goalMap = <String, CheckInGoal>{};
    for (final g in [...remote.goals, ...local.goals]) {
      final meta = g.withoutRecords();
      final existing = goalMap[meta.id];
      if (existing == null) {
        goalMap[meta.id] = meta;
      }
    }

    final recordMap = <String, CheckInRecord>{};
    for (final r in [...remote.records, ...local.records]) {
      final existing = recordMap[r.id];
      if (existing == null || r.timestamp.isAfter(existing.timestamp)) {
        recordMap[r.id] = r;
      }
    }

    final mergedRecords = recordMap.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return CheckInDocument(
      goals: goalMap.values.toList(),
      records: mergedRecords,
    );
  }

  String toMarkdown() {
    final payload = {
      'goals': goals.map((g) => g.withoutRecords().toJson()).toList(),
      'records': records.map((r) => r.toJson()).toList(),
    };
    final body = const JsonEncoder.withIndent('  ').convert(payload);
    final now = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    return '---\n'
        'title: 打卡数据\n'
        'updated_at: $now\n'
        '---\n'
        '$body\n';
  }

  static CheckInDocument fromMarkdown(String markdown) {
    final body = _extractBody(markdown).trim();
    if (body.isEmpty) return empty;

    final decoded = json.decode(body);
    if (decoded is! Map) {
      throw const FormatException('打卡数据正文必须是 JSON 对象');
    }

    final goalsRaw = decoded['goals'];
    final recordsRaw = decoded['records'];

    final goals = <CheckInGoal>[];
    if (goalsRaw is List) {
      for (final item in goalsRaw) {
        if (item is! Map) continue;
        final map = item.map((k, v) => MapEntry(k.toString(), v));
        goals.add(CheckInGoal.fromJson(map));
      }
    }

    final records = <CheckInRecord>[];
    if (recordsRaw is List) {
      for (final item in recordsRaw) {
        if (item is! Map) continue;
        final map = item.map((k, v) => MapEntry(k.toString(), v));
        records.add(CheckInRecord.fromJson(map));
      }
    }
    records.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return CheckInDocument(goals: goals, records: records);
  }

  /// 仓库内照片路径，如 images/乖乖/{recordId}.jpg
  static String imagePathFor({
    required String userEmail,
    required String recordId,
  }) {
    final folder = KnownGoogleUsers.photoFolderFor(userEmail);
    return '$imagesDir/$folder/$recordId.jpg';
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
