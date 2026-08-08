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
  });
}
