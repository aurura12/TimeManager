import 'dart:convert';

import 'package:intl/intl.dart';

import 'check_in_goal.dart';
import 'check_in_record.dart';
import 'known_google_users.dart';

/// GitHub 上的打卡数据文档（`check_in_data.md`）
class CheckInDocument {
  static const String filePath = 'check_in_data.md';
  static const String imagesDir = 'images';
  static const int currentVersion = 2;

  final List<CheckInGoal> goals;
  final List<CheckInRecord> records;

  /// 已删除目标/记录的 tombstone id，防止 merge 时被旧副本复活。
  /// 个人双人 App 数据量小，长期累积可接受；如需裁剪需权衡离线期复活风险。
  final Set<String> deletedGoalIds;
  final Set<String> deletedRecordIds;

  const CheckInDocument({
    required this.goals,
    required this.records,
    this.deletedGoalIds = const {},
    this.deletedRecordIds = const {},
  });

  static const empty = CheckInDocument(goals: [], records: []);

  /// 将扁平记录挂到各目标上，供 UI 使用
  List<CheckInGoal> goalsWithRecords() {
    return goals.map((goal) {
      final goalRecords = records.where((r) => r.goalId == goal.id).toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return goal.copyWith(records: goalRecords);
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// 给缺少 updatedAt 的目标补齐时间戳（纯函数，无副作用）。
  ///
  /// 调用方应在本地与远端完成合并后调用，避免把旧本地数据误判为最新修改。
  /// 无需补齐时原样返回同一实例，调用方可据此跳过落盘。
  CheckInDocument withLegacyGoalTimestamps(int nowMs) {
    if (goals.every((g) => g.updatedAt > 0)) return this;
    return CheckInDocument(
      goals: [
        for (final g in goals)
          g.updatedAt > 0 ? g : g.copyWith(updatedAt: nowMs),
      ],
      records: records,
      deletedGoalIds: deletedGoalIds,
      deletedRecordIds: deletedRecordIds,
    );
  }

  CheckInDocument upsertGoal(CheckInGoal goal) {
    final meta = goal.withoutRecords();
    final nextGoals = [...goals.where((g) => g.id != meta.id), meta];
    return CheckInDocument(
      goals: nextGoals,
      records: records,
      deletedGoalIds: deletedGoalIds,
      deletedRecordIds: deletedRecordIds,
    );
  }

  CheckInDocument upsertRecord(CheckInRecord record) {
    final nextRecords = [...records.where((r) => r.id != record.id), record]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return CheckInDocument(
      goals: goals,
      records: nextRecords,
      deletedGoalIds: deletedGoalIds,
      deletedRecordIds: deletedRecordIds,
    );
  }

  CheckInDocument removeRecord(String recordId) {
    final nextRecords = records.where((r) => r.id != recordId).toList();
    return CheckInDocument(
      goals: goals,
      records: nextRecords,
      deletedGoalIds: deletedGoalIds,
      deletedRecordIds: deletedRecordIds,
    );
  }

  /// 删除目标；默认同时删除该目标下的所有打卡记录
  CheckInDocument removeGoal(String goalId, {bool removeRecords = true}) {
    final nextGoals = goals.where((g) => g.id != goalId).toList();
    final nextRecords = removeRecords
        ? records.where((r) => r.goalId != goalId).toList()
        : records;
    return CheckInDocument(
      goals: nextGoals,
      records: nextRecords,
      deletedGoalIds: deletedGoalIds,
      deletedRecordIds: deletedRecordIds,
    );
  }

  /// 删除目标并写入 tombstone（防止 merge 复活）；同时删除其所有记录
  CheckInDocument tombstoneGoal(String goalId) {
    final nextGoals = goals.where((g) => g.id != goalId).toList();
    final nextRecords = records.where((r) => r.goalId != goalId).toList();
    final goalRecordIds =
        records.where((r) => r.goalId == goalId).map((r) => r.id);
    return CheckInDocument(
      goals: nextGoals,
      records: nextRecords,
      deletedGoalIds: {...deletedGoalIds, goalId},
      deletedRecordIds: {...deletedRecordIds, ...goalRecordIds},
    );
  }

  /// 删除单条打卡记录并写入 tombstone（防止 merge 复活）
  CheckInDocument tombstoneRecord(String recordId) {
    final nextRecords = records.where((r) => r.id != recordId).toList();
    return CheckInDocument(
      goals: goals,
      records: nextRecords,
      deletedGoalIds: deletedGoalIds,
      deletedRecordIds: {...deletedRecordIds, recordId},
    );
  }

  /// 合并本地与远端（按 id 去重，同 id 保留较新的记录）
  /// 目标（goal）元数据采用 "remote-first" 策略（首个出现者胜），
  /// 因为目标名称/图标等元数据变更较少，remote wns 策略可避免冲突。
  /// 记录（record）采用时间戳比较，保留较新的。
  /// 已被 tombstone 标记删除的目标/记录不参与合并（不会复活）。
  static CheckInDocument merge(CheckInDocument local, CheckInDocument remote) {
    final deletedGoals = {...local.deletedGoalIds, ...remote.deletedGoalIds};
    final deletedRecords = {
      ...local.deletedRecordIds,
      ...remote.deletedRecordIds,
    };

    final goalMap = <String, CheckInGoal>{};
    for (final g in [...remote.goals, ...local.goals]) {
      if (deletedGoals.contains(g.id)) continue; // 已删目标不复活
      final meta = g.withoutRecords();
      final existing = goalMap[meta.id];
      // 与记录一致：同 id 取 updatedAt 大者（严格大于才替换，平局保留先到的
      // 远端）。目标旧数据 updatedAt 为 0，需在合并完成后再补齐，不能让旧本地
      // 数据在拉取远端前凭空获得一个比远端更新的时间戳。
      if (existing == null || meta.updatedAt > existing.updatedAt) {
        goalMap[meta.id] = meta;
      }
    }

    final recordMap = <String, CheckInRecord>{};
    for (final r in [...remote.records, ...local.records]) {
      if (deletedRecords.contains(r.id)) continue; // 已删记录不复活
      if (deletedGoals.contains(r.goalId)) continue; // 目标已删则其记录一并排除
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
      deletedGoalIds: deletedGoals,
      deletedRecordIds: deletedRecords,
    );
  }

  String toMarkdown() {
    final body = toSyncPayload();
    final now = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    return '---\n'
        'title: 打卡数据\n'
        'updated_at: $now\n'
        '---\n'
        '$body\n';
  }

  /// 只包含业务数据的稳定序列化结果，不包含 Markdown 的写入时间。
  ///
  /// `updated_at` 每次生成 Markdown 都会变化，不能用完整文件内容判断
  /// 是否真的有数据变化，否则同步中心重试会不断创建空提交。
  String toSyncPayload() {
    final sortedGoals = goals.map((goal) => goal.withoutRecords()).toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    final sortedRecords = List<CheckInRecord>.from(records)
      ..sort((left, right) => left.id.compareTo(right.id));
    final payload = {
      'version': currentVersion,
      'goals': sortedGoals.map((goal) => goal.toJson()).toList(),
      'records': sortedRecords.map((record) => record.toJson()).toList(),
      'deleted_goals': deletedGoalIds.toList()..sort(),
      'deleted_records': deletedRecordIds.toList()..sort(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
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
        final record = _tryParseRecord(item);
        if (record != null) records.add(record);
      }
    }
    records.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // v1 数据无 tombstone 字段，默认空集合（零迁移）
    final deletedGoals = <String>{};
    final deletedRecords = <String>{};
    final deletedGoalsRaw = decoded['deleted_goals'];
    if (deletedGoalsRaw is List) {
      for (final item in deletedGoalsRaw) {
        if (item is String && item.isNotEmpty) deletedGoals.add(item);
      }
    }
    final deletedRecordsRaw = decoded['deleted_records'];
    if (deletedRecordsRaw is List) {
      for (final item in deletedRecordsRaw) {
        if (item is String && item.isNotEmpty) deletedRecords.add(item);
      }
    }

    return CheckInDocument(
      goals: goals,
      records: records,
      deletedGoalIds: deletedGoals,
      deletedRecordIds: deletedRecords,
    );
  }

  /// 解析单条记录时隔离损坏数据，避免一条旧/坏记录阻断整个文档同步。
  ///
  /// 正常文档仍使用 [CheckInRecord.fromJson] 的既有格式；这里只在进入模型
  /// 前拒绝缺少必填字段或字段类型明显错误的条目，并将解析异常限制在当前条目。
  static CheckInRecord? _tryParseRecord(Object? item) {
    if (item is! Map) return null;

    try {
      final map = item.map((k, v) => MapEntry(k.toString(), v));
      if (!_isValidRecordShape(map)) return null;
      return CheckInRecord.fromJson(map);
    } on Object {
      // 单条损坏记录不应让其他有效记录无法同步。
      return null;
    }
  }

  static bool _isValidRecordShape(Map<String, dynamic> map) {
    const requiredStringFields = [
      'id',
      'goal_id',
      'user_id',
      'user_email',
      'timestamp',
    ];
    for (final field in requiredStringFields) {
      final value = map[field];
      if (value is! String || value.trim().isEmpty) return false;
    }

    if (DateTime.tryParse(map['timestamp'] as String) == null) return false;

    const optionalStringFields = [
      'user_display_name',
      'location_name',
      'photo_path',
      'note',
    ];
    for (final field in optionalStringFields) {
      final value = map[field];
      if (value != null && value is! String) return false;
    }

    for (final field in ['latitude', 'longitude']) {
      final value = map[field];
      if (value != null && !_isFiniteNumber(value)) return false;
    }

    final isBackfill = map['is_backfill'];
    return isBackfill == null || isBackfill is bool;
  }

  static bool _isFiniteNumber(Object value) {
    if (value is num) return value.isFinite;
    if (value is String) {
      final parsed = double.tryParse(value);
      return parsed != null && parsed.isFinite;
    }
    return false;
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
