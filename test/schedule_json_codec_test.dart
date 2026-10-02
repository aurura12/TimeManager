import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/services/schedule_json_codec.dart';

void main() {
  test('后台增量编码保留其它日期、墓碑和日历元数据，只替换脏日期', () async {
    final untouched = [
      {'i': 0, 'del': true, 'ts': 123},
      {'i': 1, 'l': '会议', 'fc': true, 'eid': 'calendar-id', 'ts': 456},
    ];
    final encoded = await compute(
      encodeScheduleJsonPatch,
      ScheduleJsonPatch(
        existingJson: jsonEncode({
          '2026-09-01': untouched,
          '2026-09-02': [
            {'i': 0, 'l': '旧记录'},
          ],
          '2026-09-03': [
            {'i': 0, 'l': '待移除'},
          ],
        }),
        changedDays: {
          '2026-09-02': [
            {'i': 48, 'l': '新记录', 'cid': 'focus', 'ts': 789},
          ],
          '2026-09-03': [],
        },
      ),
    );
    final root = jsonDecode(encoded) as Map;
    expect(root['2026-09-01'], untouched);
    expect(root['2026-09-02'], [
      {'i': 48, 'l': '新记录', 'cid': 'focus', 'ts': 789},
    ]);
    expect(root.containsKey('2026-09-03'), isFalse);
  });

  test('损坏历史拒绝编码，不会被脏日期覆盖成半份历史', () async {
    await expectLater(
      compute(
        encodeScheduleJsonPatch,
        const ScheduleJsonPatch(
          existingJson: '{坏历史',
          changedDays: {'2026-09-02': []},
        ),
      ),
      throwsFormatException,
    );
  });

  test('后台读取只返回所需日期，并保留原始字段顺序供旧哈希兼容', () async {
    final day = [
      {'i': 48, 'l': '工作', 'c': 4288452714, 'ts': 123, 'cid': 'focus'},
    ];
    final root = await readScheduleJsonDays(
      jsonEncode({
        '2020-01-01': [
          {'i': 0, 'l': '历史记录'},
        ],
        '2026-09-02': day,
      }),
      dateKeys: {'2026-09-02', '2026-09-03'},
    );
    expect(root!.keys, ['2026-09-02']);
    expect(jsonEncode(root['2026-09-02']), jsonEncode(day));
  });

  test('索引读取限制返回日期数，损坏和缺失 JSON 保留空数据语义', () async {
    final root = await readScheduleJsonDays(
      jsonEncode({'a': [], 'b': [], 'c': []}),
      maxDays: 2,
    );
    expect(root!.keys, ['a', 'b']);
    expect(await readScheduleJsonDays(null), isNull);
    expect(await readScheduleJsonDays('{坏数据'), isNull);
    expect(await readScheduleJsonDays('{}'), isEmpty);
  });
}
