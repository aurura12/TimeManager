import '../models/changelog_entry.dart';

/// 版本分节标题：`## 1.176.0+2065（2026-11-17）`。
///
/// 构建号与日期是可选的，历史数据缺失时也能解析出来（对应字段留空），
/// 避免一次格式漂移就让整页变空。
final RegExp _headingPattern = RegExp(
  r'^##\s+(\d+\.\d+\.\d+)(?:\+(\d+))?(?:\s*（(\d{4}-\d{2}-\d{2})）)?\s*$',
);

/// 把 docs/release-notes.md 解析成按文件顺序排列的日志条目。
///
/// 约定：文件已按版本倒序排列，解析器不重排；空文本返回空列表。
List<ChangelogEntry> parseChangelog(String raw) {
  final entries = <ChangelogEntry>[];
  var hasHeading = false;
  var version = '';
  var build = '';
  DateTime? date;
  var bullets = <String>[];

  void flush() {
    if (!hasHeading || version.isEmpty) return;
    entries.add(ChangelogEntry(
      version: version,
      build: build,
      date: date,
      bullets: List<String>.unmodifiable(bullets),
    ));
  }

  for (final line in raw.split('\n')) {
    final trimmed = line.trim();
    final heading = _headingPattern.firstMatch(trimmed);
    if (heading != null) {
      flush();
      hasHeading = true;
      version = heading.group(1)!;
      build = heading.group(2) ?? '';
      final dateText = heading.group(3);
      date = dateText == null ? null : DateTime.tryParse(dateText);
      bullets = <String>[];
      continue;
    }
    if (!hasHeading || trimmed.isEmpty) continue;

    if (trimmed.startsWith('- ')) {
      bullets.add(trimmed.substring(2).trim());
    } else if (bullets.isNotEmpty) {
      // 文件里手动折行的条目：续接到上一条，不产生半句话。
      bullets[bullets.length - 1] = '${bullets.last}$trimmed';
    }
  }
  flush();
  return entries;
}
