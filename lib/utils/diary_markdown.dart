/// 日记 Markdown 的正文处理。
///
/// 两个函数刻意分开：
/// - [stripDiaryFrontMatter] 只剥掉 YAML front matter，保持正文原样（用于编辑器回填）；
/// - [normalizeDiaryBody] 在剥离后还会统一换行并 trim（用于比较与差分）。
library;

final RegExp _frontMatterPattern =
    RegExp(r'^---\n([\s\S]*?)\n---\n?', multiLine: false);

/// 去掉开头的 `--- … ---` front matter；没有 front matter 时原样返回。
///
/// 不做换行归一，避免把 CRLF 文档的字节改掉。
String stripDiaryFrontMatter(String markdown) {
  final match = _frontMatterPattern.firstMatch(markdown);
  if (match == null) return markdown;
  return markdown.substring(match.end);
}

/// 比较用的归一化正文：统一换行、去 front matter、trim。
String normalizeDiaryBody(String markdown) {
  return stripDiaryFrontMatter(markdown.replaceAll('\r\n', '\n')).trim();
}
