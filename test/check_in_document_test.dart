import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/check_in_document.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/check_in_record.dart';

CheckInGoal _goal(String id, {String email = 'test@example.com'}) {
  return CheckInGoal(
    id: id,
    ownerId: 'uid-$id',
    ownerEmail: email,
    ownerDisplayName: 'T',
    name: '目标$id',
    description: '',
    color: const Color(0xFF000000),
    icon: Icons.flag,
    period: CheckInPeriod.daily,
    targetCount: 1,
  );
}

CheckInRecord _record(String id, String goalId, DateTime ts) {
  return CheckInRecord(
    id: id,
    goalId: goalId,
    userId: 'uid',
    userEmail: 'test@example.com',
    timestamp: ts,
  );
}

void main() {
  group('CheckInDocument tombstone', () {
    test('删除的目标在 merge 时不复活', () {
      final goal = _goal('g1');
      final local = CheckInDocument(goals: [goal], records: []).tombstoneGoal('g1');
      final remote = CheckInDocument(goals: [goal], records: []);

      final merged = CheckInDocument.merge(local, remote);
      expect(merged.goals.any((g) => g.id == 'g1'), isFalse);
    });

    test('删除的记录在 merge 时不复活', () {
      final goal = _goal('g1');
      final rec = _record('r1', 'g1', DateTime(2026, 1, 1));
      final local =
          CheckInDocument(goals: [goal], records: [rec]).tombstoneRecord('r1');
      final remote = CheckInDocument(goals: [goal], records: [rec]);

      final merged = CheckInDocument.merge(local, remote);
      expect(merged.records.any((r) => r.id == 'r1'), isFalse);
    });

    test('删除目标会连带其记录一并排除', () {
      final goal = _goal('g1');
      final rec = _record('r1', 'g1', DateTime(2026, 1, 1));
      final local =
          CheckInDocument(goals: [goal], records: [rec]).tombstoneGoal('g1');
      final remote = CheckInDocument(goals: [goal], records: [rec]);

      final merged = CheckInDocument.merge(local, remote);
      expect(merged.goals, isEmpty);
      expect(merged.records.any((r) => r.goalId == 'g1'), isFalse);
    });

    test('tombstone 集合随文档传播', () {
      final goal = _goal('g1');
      final local =
          CheckInDocument(goals: [goal], records: []).tombstoneGoal('g1');
      final remote = CheckInDocument(goals: [], records: []);

      final merged = CheckInDocument.merge(local, remote);
      expect(merged.deletedGoalIds, contains('g1'));
    });

    test('序列化 round-trip 保留 tombstone', () {
      final goal = _goal('g1');
      final doc = CheckInDocument(goals: [goal], records: [])
          .tombstoneGoal('g1');
      final parsed = CheckInDocument.fromMarkdown(doc.toMarkdown());
      expect(parsed.deletedGoalIds, contains('g1'));
      expect(parsed.goals, isEmpty);
    });
  });

  group('CheckInDocument v1 兼容', () {
    test('无 version/deleted 字段的旧数据解析成功', () {
      const v1Markdown = '---\n'
          'title: 打卡数据\n'
          'updated_at: 2026-01-01 00:00:00\n'
          '---\n'
          '{"goals": [], "records": []}\n';
      final doc = CheckInDocument.fromMarkdown(v1Markdown);
      expect(doc.goals, isEmpty);
      expect(doc.records, isEmpty);
      expect(doc.deletedGoalIds, isEmpty);
      expect(doc.deletedRecordIds, isEmpty);
    });

    test('常规 union 合并行为不回归', () {
      final g1 = _goal('g1');
      final g2 = _goal('g2');
      final local = CheckInDocument(goals: [g1], records: []);
      final remote = CheckInDocument(goals: [g2], records: []);

      final merged = CheckInDocument.merge(local, remote);
      expect(merged.goals.length, 2);
    });
  });
}
