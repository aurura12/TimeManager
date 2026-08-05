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
  });
}
