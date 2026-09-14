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

  group('CheckInGoal updatedAt 合并', () {
    test('本地改名后 merge 不会被远端旧值覆盖', () {
      final remoteGoal = _goal('g1').copyWith(updatedAt: 1000);
      final localGoal = _goal('g1').copyWith(name: '晨跑', updatedAt: 2000);

      final merged = CheckInDocument.merge(
        CheckInDocument(goals: [localGoal], records: []),
        CheckInDocument(goals: [remoteGoal], records: []),
      );

      expect(merged.goals.single.name, '晨跑');
    });

    test('参数顺序颠倒时结果一致（本地/远端对称）', () {
      final a = _goal('g1').copyWith(name: '晨跑', updatedAt: 2000);
      final b = _goal('g1').copyWith(name: '跑步', updatedAt: 1000);

      final merged1 = CheckInDocument.merge(
        CheckInDocument(goals: [a], records: []),
        CheckInDocument(goals: [b], records: []),
      );
      final merged2 = CheckInDocument.merge(
        CheckInDocument(goals: [b], records: []),
        CheckInDocument(goals: [a], records: []),
      );

      expect(merged1.goals.single.name, '晨跑');
      expect(merged2.goals.single.name, '晨跑');
    });

    test('远端更新（时间戳更大）时以远端为准', () {
      final localGoal = _goal('g1').copyWith(name: '晨跑', updatedAt: 1000);
      final remoteGoal = _goal('g1').copyWith(name: '夜跑', updatedAt: 5000);

      final merged = CheckInDocument.merge(
        CheckInDocument(goals: [localGoal], records: []),
        CheckInDocument(goals: [remoteGoal], records: []),
      );

      expect(merged.goals.single.name, '夜跑');
    });

    test('改描述/图标/周期/次数同样生效', () {
      final remoteGoal = _goal('g1').copyWith(updatedAt: 1000);
      final localGoal = _goal('g1').copyWith(
        description: '每天五公里',
        period: CheckInPeriod.weekly,
        targetCount: 5,
        updatedAt: 2000,
      );

      final merged = CheckInDocument.merge(
        CheckInDocument(goals: [localGoal], records: []),
        CheckInDocument(goals: [remoteGoal], records: []),
      );

      final result = merged.goals.single;
      expect(result.description, '每天五公里');
      expect(result.period, CheckInPeriod.weekly);
      expect(result.targetCount, 5);
    });

    test('两端都是旧数据（时间戳为 0）时保持远端优先，不引入新行为', () {
      final localGoal = _goal('g1').copyWith(name: '本地名');
      final remoteGoal = _goal('g1').copyWith(name: '远端名');

      final merged = CheckInDocument.merge(
        CheckInDocument(goals: [localGoal], records: []),
        CheckInDocument(goals: [remoteGoal], records: []),
      );

      expect(merged.goals.single.name, '远端名');
    });

    test('合并保留记录、不因元数据时间戳影响记录合并', () {
      final remoteGoal = _goal('g1').copyWith(updatedAt: 1000);
      final localGoal = _goal('g1').copyWith(name: '晨跑', updatedAt: 2000);
      final rec = _record('r1', 'g1', DateTime(2026, 1, 1));

      final merged = CheckInDocument.merge(
        CheckInDocument(goals: [localGoal], records: [rec]),
        CheckInDocument(goals: [remoteGoal], records: []),
      );

      expect(merged.goals.single.name, '晨跑');
      expect(merged.records.single.id, 'r1');
    });

    test('updatedAt 序列化 round-trip，旧数据缺字段为 0', () {
      final goal = _goal('g1').copyWith(updatedAt: 1700000000000);
      expect(CheckInGoal.fromJson(goal.toJson()).updatedAt, 1700000000000);

      final legacy = _goal('g2').toJson()..remove('updated_at');
      expect(CheckInGoal.fromJson(legacy).updatedAt, 0);

      final stringTs = _goal('g3').toJson()..['updated_at'] = '1700000000000';
      expect(CheckInGoal.fromJson(stringTs).updatedAt, 1700000000000);
    });

    test('withoutRecords 保留 updatedAt', () {
      final goal = _goal('g1').copyWith(updatedAt: 1234);
      expect(goal.withoutRecords().updatedAt, 1234);
    });
  });

  group('CheckInDocument 旧目标时间戳迁移', () {
    test('缺 updatedAt 的旧目标被补齐，其余目标不受影响', () {
      final legacy = _goal('g1');
      final stamped = _goal('g2').copyWith(updatedAt: 999);

      final migrated = CheckInDocument(
        goals: [legacy, stamped],
        records: [],
      ).withLegacyGoalTimestamps(5000);

      expect(migrated.goals.firstWhere((g) => g.id == 'g1').updatedAt, 5000);
      expect(migrated.goals.firstWhere((g) => g.id == 'g2').updatedAt, 999);
    });

    test('全部已有时间戳时不产生新实例（调用方可跳过落盘）', () {
      final doc = CheckInDocument(
        goals: [_goal('g1').copyWith(updatedAt: 999)],
        records: [],
      );
      expect(identical(doc.withLegacyGoalTimestamps(5000), doc), isTrue);
    });

    test('迁移后本地编辑能在 merge 中胜出', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      // 本地旧数据（无时间戳）→ 迁移补时间戳 → 用户改名
      final migrated = CheckInDocument(
        goals: [_goal('g1')],
        records: [],
      ).withLegacyGoalTimestamps(nowMs);
      final edited = CheckInDocument(
        goals: [migrated.goals.single.copyWith(name: '晨跑', updatedAt: nowMs + 1)],
        records: [],
      );
      // 远端仍是旧的、且没有时间戳
      final remote = CheckInDocument(goals: [_goal('g1')], records: []);

      final merged = CheckInDocument.merge(edited, remote);
      expect(merged.goals.single.name, '晨跑');
    });

    test('迁移保留记录与墓碑集合', () {
      final rec = _record('r1', 'g1', DateTime(2026, 1, 1));
      final doc = CheckInDocument(
        goals: [_goal('g1')],
        records: [rec],
        deletedGoalIds: {'gone'},
      ).withLegacyGoalTimestamps(5000);

      expect(doc.records.single.id, 'r1');
      expect(doc.deletedGoalIds, {'gone'});
    });
  });
}
