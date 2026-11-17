/// 一条更新日志：对应 docs/release-notes.md 里的一个版本分节。
class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.build,
    required this.bullets,
    this.date,
  });

  /// 版本名，例如 1.176.0。
  final String version;

  /// 构建号，历史条目可能缺失（旧格式），此时为空字符串。
  final String build;

  final DateTime? date;

  /// 本版改动，1-3 条。
  final List<String> bullets;

  /// 版本 + 构建号，与 pubspec.yaml 的 version 字段同形。
  String get label => build.isEmpty ? version : '$version+$build';
}
