import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/services/schedule_overwrite.dart';

void main() {
  test('accepts only padded canonical paths for the selected user', () {
    expect(
      ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
        'schedule/g/2026-09-06.json',
        userCode: 'g',
      ),
      isTrue,
    );
    expect(
      ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
        'schedule/g/2026-9-6.json',
        userCode: 'g',
      ),
      isFalse,
    );
    expect(
      ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
        'schedule/j/2026-09-06.json',
        userCode: 'g',
      ),
      isFalse,
    );
    expect(
      ScheduleOverwriteSnapshot.dateKeyFromCanonicalPath(
        'schedule/g/2026-09-06.json',
        userCode: 'g',
      ),
      '2026-09-06',
    );
    expect(
      ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
        'schedule/x/2026-09-06.json',
        userCode: 'x',
      ),
      isFalse,
    );
  });

  test('parses object and legacy array forms and ignores unpadded paths', () {
    final result = ScheduleOverwriteSnapshot.fromRemoteFiles(
      userCode: 'g',
      contentsByPath: {
        'schedule/g/2026-09-06.json': jsonEncode({
          'updated_at': 10,
          'slots': [
            {'i': 2, 'l': '对象'},
          ],
        }),
        'schedule/g/2026-9-7.json': '[{"i": 1, "l": "忽略"}]',
        'schedule/g/2026-09-08.json': '[{"i": 4, "l": "旧数组"}]',
      },
    );

    expect(result.isValid, isTrue);
    expect(result.entriesByDate, {
      '2026-09-06': [
        {'i': 2, 'l': '对象'},
      ],
      '2026-09-08': [
        {'i': 4, 'l': '旧数组'},
      ],
    });
  });

  test('fromRemoteFiles returns only entries in the selected user namespace',
      () {
    final result = ScheduleOverwriteSnapshot.fromRemoteFiles(
      userCode: 'g',
      contentsByPath: {
        'schedule/g/2026-09-06.json': '[{"i": 1, "l": "乖乖"}]',
        'schedule/j/2026-09-06.json': '[{"i": 2, "l": "晶晶"}]',
      },
    );

    expect(result.isValid, isTrue);
    expect(result.entriesByDate, {
      '2026-09-06': [
        {'i': 1, 'l': '乖乖'},
      ],
    });
  });

  final invalidCases = <String, String>{
    'malformed JSON': '{',
    'non-list slots': '{"updated_at": 1, "slots": {}}',
    'non-map slot': '{"slots": [1]}',
    'non-integer index': '{"slots": [{"i": 1.5, "l": "x"}]}',
    'out-of-range index': '{"slots": [{"i": 144, "l": "x"}]}',
    'duplicate index': '{"slots": [{"i": 1, "l": "a"}, {"i": 1, "l": "b"}]}',
    'empty required field': '{"slots": [{"i": 1, "l": ""}]}',
    'missing required field': '{"slots": [{"i": 1}]}',
    'wrongly typed required field': '{"slots": [{"i": 1, "l": 123}]}',
    'wrongly typed force-color field':
        '{"slots": [{"i": 1, "l": "x", "fc": "false"}]}',
  };

  for (final entry in invalidCases.entries) {
    test('invalidates the entire snapshot for ${entry.key}', () {
      final result = ScheduleOverwriteSnapshot.fromRemoteFiles(
        userCode: 'g',
        contentsByPath: {
          'schedule/g/2026-09-06.json': entry.value,
          'schedule/g/2026-09-07.json': '[{"i": 2, "l": "must not apply"}]',
        },
      );

      expect(result.isValid, isFalse);
      expect(result.entriesByDate, isEmpty);
      expect(result.error, isNotNull);
    });
  }

  test('sorts valid entries by index and retains a legal tombstone', () {
    final result = ScheduleOverwriteSnapshot.fromRemoteFiles(
      userCode: 'g',
      contentsByPath: {
        'schedule/g/2026-09-06.json': jsonEncode({
          'slots': [
            {'i': 10, 'l': '晚', 'ts': 3},
            {'i': 3, 'del': true, 'ts': 4},
            {'i': 1, 'l': '早', 'cid': 'c'},
          ],
        }),
      },
    );

    expect(result.isValid, isTrue);
    expect(result.entriesByDate['2026-09-06']!.map((e) => e['i']), [1, 3, 10]);
    expect(result.entriesByDate['2026-09-06']![1], {
      'i': 3,
      'del': true,
      'ts': 4,
    });
  });
}
