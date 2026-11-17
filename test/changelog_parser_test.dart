import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/changelog_parser.dart';

void main() {
  test('parses version headings with build and date', () {
    const raw = '''
## 1.2.0+3（2026-05-28）

- 第一条。
- 第二条。

## 1.1.0+2

- 只有版本和构建号。
''';
    final entries = parseChangelog(raw);

    expect(entries, hasLength(2));
    expect(entries[0].version, '1.2.0');
    expect(entries[0].build, '3');
    expect(entries[0].date, DateTime(2026, 5, 28));
    expect(entries[0].bullets, ['第一条。', '第二条。']);
    expect(entries[0].label, '1.2.0+3');
    expect(entries[1].date, isNull);
  });

  test('joins wrapped bullet lines and keeps order', () {
    const raw = '''
## 2.0.0+10（2026-06-01）

- 前半句，
  后半句。
- 另一条。
''';
    final entries = parseChangelog(raw);

    expect(entries, hasLength(1));
    expect(entries.single.bullets, ['前半句，后半句。', '另一条。']);
  });

  test('ignores text before the first heading and blank input', () {
    expect(parseChangelog(''), isEmpty);
    expect(parseChangelog('   \n\n'), isEmpty);
    expect(
        parseChangelog('更新日志\n\n## 1.0.0+1（2026-01-01）\n\n- 内容。').single.label,
        '1.0.0+1');
  });

  test('repository changelog covers every version and stays ordered', () {
    final entries =
        parseChangelog(File('docs/release-notes.md').readAsStringSync());
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([^\s#]+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);

    expect(entries.length, greaterThanOrEqualTo(56));
    expect(entries.first.label, version,
        reason: '最新一条必须与 pubspec.yaml 的 version 一致');
    expect(
        entries.map((entry) => entry.label).toSet(), hasLength(entries.length),
        reason: '同一个版本+构建号只能出现一次');

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      expect(entry.bullets.length, inInclusiveRange(1, 3), reason: entry.label);
      if (i == 0) continue;
      final previous = entries[i - 1].date;
      final current = entry.date;
      if (previous != null && current != null) {
        expect(current.isAfter(previous), isFalse,
            reason: '日期必须不增：$previous -> $current');
      }
    }
  });
}
