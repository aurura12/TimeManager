import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/services/schedule_day_merge.dart';

void main() {
  group('parseScheduleContent', () {
    test('解析新对象格式', () {
      const content =
          '{"updated_at": 2000, "slots": [{"i": 0, "l": "跑步", "ts": 1000}]}';
      final result = parseScheduleContent(content);
      expect(result.updatedAt, 2000);
      expect(result.slots.length, 1);
      expect(result.slots.first['i'], 0);
    });

    test('解析旧裸数组格式（updatedAt=0）', () {
      const content = '[{"i": 0, "l": "跑步"}]';
      final result = parseScheduleContent(content);
      expect(result.updatedAt, 0);
      expect(result.slots.length, 1);
    });

    test('null / 空 / 非法内容返回空', () {
      expect(parseScheduleContent(null).slots, isEmpty);
      expect(parseScheduleContent('').slots, isEmpty);
      expect(parseScheduleContent('not json').slots, isEmpty);
    });
  });

  group('mergeScheduleSlots', () {
    test('冲突时 ts 大者胜', () {
      final local = [
        {'i': 0, 'l': '本地', 'ts': 1000},
      ];
      final remote = [
        {'i': 0, 'l': '远端', 'ts': 2000},
      ];
      final merged = mergeScheduleSlots(
        localEntries: local,
        remoteEntries: remote,
      );
      expect(merged.length, 1);
      expect(merged.first['l'], '远端');
    });

    test('平局取本地', () {
      final local = [
        {'i': 0, 'l': '本地', 'ts': 1000},
      ];
      final remote = [
        {'i': 0, 'l': '远端', 'ts': 1000},
      ];
      final merged = mergeScheduleSlots(
        localEntries: local,
        remoteEntries: remote,
      );
      expect(merged.first['l'], '本地');
    });

    test('两侧不同的槽位都保留（不误删对方记录）', () {
      final local = [
        {'i': 0, 'l': 'A', 'ts': 1000},
      ];
      final remote = [
        {'i': 1, 'l': 'B', 'ts': 2000},
      ];
      final merged = mergeScheduleSlots(
        localEntries: local,
        remoteEntries: remote,
      );
      expect(merged.length, 2);
    });

    test('仅一侧有的槽始终保留（union，不丢数据）', () {
      final local = [
        {'i': 0, 'l': 'A', 'ts': 3000},
      ];
      // 本地有、远端无 → 保留本地
      final keptLocal = mergeScheduleSlots(
        localEntries: local,
        remoteEntries: const [],
      );
      expect(keptLocal.length, 1);

      final remote = [
        {'i': 1, 'l': 'B', 'ts': 4000},
      ];
      // 远端有、本地无 → 保留远端
      final keptRemote = mergeScheduleSlots(
        localEntries: const [],
        remoteEntries: remote,
      );
      expect(keptRemote.length, 1);
    });

    test('回归：同步期间本地新修改在二次合并中不被远端旧值覆盖', () {
      // 场景模拟 _pushScheduleDay：
      // 第一次 merge 用序列化时的旧本地快照（ts=1000），远端该槽位 ts=2000 → 远端胜
      final staleLocal = [
        {'i': 0, 'l': '旧本地', 'ts': 1000},
      ];
      final remote = [
        {'i': 0, 'l': '远端', 'ts': 2000},
      ];
      final merged = mergeScheduleSlots(
        localEntries: staleLocal,
        remoteEntries: remote,
      );
      expect(merged.first['l'], '远端');

      // 同步期间用户又编辑了同一槽位（ts=3000），写回前用最新本地再次合并：
      // 最新本地必须胜出，否则用户的新修改会被覆盖回旧数据
      final latestLocal = [
        {'i': 0, 'l': '用户新修改', 'ts': 3000},
      ];
      final finalEntries = mergeScheduleSlots(
        localEntries: latestLocal,
        remoteEntries: merged,
      );
      expect(finalEntries.first['l'], '用户新修改');
    });

    test('本地明确清空日程时，推送内容必须为空而不是合并回远端记录', () {
      final remote = [
        {'i': 0, 'l': '旧日程', 'ts': 1000},
      ];

      final pushed = scheduleEntriesForPush(
        localEntries: const [],
        remoteEntries: remote,
      );

      expect(pushed, isEmpty);
    });
  });

  group('tombstone（删除墓碑）', () {
    test('parseScheduleContent 解析 del:true entry', () {
      const content =
          '{"updated_at": 2000, "slots": [{"i": 3, "del": true, "ts": 1500}]}';
      final result = parseScheduleContent(content);
      expect(result.slots.length, 1);
      expect(result.slots.first['i'], 3);
      expect(result.slots.first['del'], true);
      expect(result.slots.first['ts'], 1500);
    });

    test('较新的 tombstone 胜过较旧的 live entry（删除传播）', () {
      // 用户删除了槽位（墓碑 ts=2000），远端还留着旧记录（live ts=1000）
      final local = [
        {'i': 0, 'del': true, 'ts': 2000},
      ];
      final remote = [
        {'i': 0, 'l': '跑步', 'ts': 1000},
      ];
      final merged = mergeScheduleSlots(
        localEntries: local,
        remoteEntries: remote,
      );
      expect(merged.length, 1);
      expect(merged.first['del'], true);
    });

    test('较新的 live entry 胜过较旧的 tombstone（重建生效）', () {
      final local = [
        {'i': 0, 'l': '新跑步', 'ts': 3000},
      ];
      final remote = [
        {'i': 0, 'del': true, 'ts': 2000},
      ];
      final merged = mergeScheduleSlots(
        localEntries: local,
        remoteEntries: remote,
      );
      expect(merged.length, 1);
      expect(merged.first['l'], '新跑步');
      expect(merged.first['del'], isNot(true));
    });

    test('双侧 tombstone 取较新的 ts', () {
      final local = [
        {'i': 0, 'del': true, 'ts': 3000},
      ];
      final remote = [
        {'i': 0, 'del': true, 'ts': 2000},
      ];
      final merged = mergeScheduleSlots(
        localEntries: local,
        remoteEntries: remote,
      );
      expect(merged.length, 1);
      expect(merged.first['del'], true);
      expect(merged.first['ts'], 3000);
    });

    test('单侧 tombstone 保留并向另一侧传播', () {
      // 本地墓碑、远端无 → 保留墓碑
      final local = [
        {'i': 1, 'del': true, 'ts': 2000},
      ];
      final keptLocal = mergeScheduleSlots(
        localEntries: local,
        remoteEntries: const [],
      );
      expect(keptLocal.length, 1);
      expect(keptLocal.first['del'], true);

      // 远端墓碑、本地无 → 保留墓碑
      final remote = [
        {'i': 2, 'del': true, 'ts': 2000},
      ];
      final keptRemote = mergeScheduleSlots(
        localEntries: const [],
        remoteEntries: remote,
      );
      expect(keptRemote.length, 1);
      expect(keptRemote.first['del'], true);
    });

    test('全天删除后推送内容非空且含墓碑（而非空数组）', () {
      // 用户把唯一槽位删了：本地序列化为墓碑，不能走"本地空→推空"特例
      final local = [
        {'i': 5, 'del': true, 'ts': 2000},
      ];
      final remote = [
        {'i': 5, 'l': '旧日程', 'ts': 1000},
      ];
      final pushed = scheduleEntriesForPush(
        localEntries: local,
        remoteEntries: remote,
      );
      expect(pushed, isNotEmpty);
      expect(pushed.first['del'], true);
    });

    test('isTombstoneEntry 识别墓碑', () {
      expect(isTombstoneEntry({'i': 0, 'del': true, 'ts': 1}), isTrue);
      expect(isTombstoneEntry({'i': 0, 'l': '跑步', 'ts': 1}), isFalse);
      expect(isTombstoneEntry({'i': 0}), isFalse);
    });
  });
}
