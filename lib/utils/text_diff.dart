/// 行级文本差异，用于日记冲突处理页。
///
/// 不引入第三方 diff 包：日记是纯文本、行数有限，标准 LCS 足够，并且纯函数
/// 好测试。比较时忽略行尾空白，展示时保留原文。
library;

enum TextDiffKind { common, removed, added }

class TextDiffLine {
  const TextDiffLine({
    required this.kind,
    required this.text,
    this.localLine,
    this.remoteLine,
  });

  final TextDiffKind kind;
  final String text;

  /// 在各自版本中的行号（从 1 开始）；对侧没有则为 null。
  final int? localLine;
  final int? remoteLine;
}

/// 一段连续内容：要么是两边相同（[isConflict] 为 false），要么是一处差异。
class TextDiffBlock {
  const TextDiffBlock({
    required this.lines,
    required this.isConflict,
    required this.localLines,
    required this.remoteLines,
  });

  final List<TextDiffLine> lines;
  final bool isConflict;

  /// 选「用本地」时这一段输出的行。
  final List<String> localLines;

  /// 选「用远端」时这一段输出的行。
  final List<String> remoteLines;
}

/// 差异块的处理方式。
enum HunkChoice { local, remote, both }

/// 超长文本直接退化成「整块替换」，避免 O(n·m) 的 DP 拖住 UI。
const int _maxCellProduct = 1000000;

/// 按行比较两个正文，返回按顺序排列的相同块与差异块。
List<TextDiffBlock> buildDiffBlocks(String local, String remote) {
  final a = _splitLines(local);
  final b = _splitLines(remote);
  if (a.length * b.length > _maxCellProduct) {
    return _fallbackBlocks(a, b);
  }

  final dp = List.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
    growable: false,
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      dp[i][j] = _sameLine(a[i], b[j])
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }

  final lines = <TextDiffLine>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (_sameLine(a[i], b[j])) {
      lines.add(TextDiffLine(
        kind: TextDiffKind.common,
        text: a[i],
        localLine: i + 1,
        remoteLine: j + 1,
      ));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      lines.add(TextDiffLine(
        kind: TextDiffKind.removed,
        text: a[i],
        localLine: i + 1,
      ));
      i++;
    } else {
      lines.add(TextDiffLine(
        kind: TextDiffKind.added,
        text: b[j],
        remoteLine: j + 1,
      ));
      j++;
    }
  }
  while (i < a.length) {
    lines.add(TextDiffLine(
      kind: TextDiffKind.removed,
      text: a[i],
      localLine: i + 1,
    ));
    i++;
  }
  while (j < b.length) {
    lines.add(TextDiffLine(
      kind: TextDiffKind.added,
      text: b[j],
      remoteLine: j + 1,
    ));
    j++;
  }
  return _groupBlocks(lines);
}

/// 默认把每个差异块都保留两边（先本地、后远端）。
List<HunkChoice> defaultHunkChoices(List<TextDiffBlock> blocks) {
  return [
    for (final block in blocks)
      if (block.isConflict) HunkChoice.both,
  ];
}

/// 按用户对每个差异块的选择拼出最终正文。
///
/// 行拆分时丢掉了结尾空行，[endWithNewline] 用来把它补回去：任一版本以换行
/// 结尾时合并结果也以换行结尾，避免合并一次就把远端文件的行尾改掉。
String mergeDiffBlocks(
  List<TextDiffBlock> blocks,
  List<HunkChoice> choices, {
  bool endWithNewline = false,
}) {
  final output = <String>[];
  var index = 0;
  for (final block in blocks) {
    if (!block.isConflict) {
      output.addAll(block.localLines);
      continue;
    }
    final choice =
        index < choices.length ? choices[index] : HunkChoice.both;
    index++;
    switch (choice) {
      case HunkChoice.local:
        output.addAll(block.localLines);
      case HunkChoice.remote:
        output.addAll(block.remoteLines);
      case HunkChoice.both:
        output
          ..addAll(block.localLines)
          ..addAll(block.remoteLines);
    }
  }
  final merged = output.join('\n');
  if (!endWithNewline || merged.isEmpty) return merged;
  return '$merged\n';
}

/// 正文是否以换行结尾（`\r\n` 也认）。
bool textEndsWithNewline(String text) => text.endsWith('\n');

List<String> _splitLines(String text) {
  if (text.isEmpty) return const [];
  final normalized = text.replaceAll('\r\n', '\n');
  final lines = normalized.split('\n');
  // 末尾换行只是排版，不单独算一行。
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

bool _sameLine(String a, String b) => a.trimRight() == b.trimRight();

List<TextDiffBlock> _fallbackBlocks(List<String> a, List<String> b) {
  if (a.length == b.length) {
    var identical = true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        identical = false;
        break;
      }
    }
    if (identical) {
      return [
        TextDiffBlock(
          lines: [
            for (var i = 0; i < a.length; i++)
              TextDiffLine(
                kind: TextDiffKind.common,
                text: a[i],
                localLine: i + 1,
                remoteLine: i + 1,
              ),
          ],
          isConflict: false,
          localLines: a,
          remoteLines: b,
        ),
      ];
    }
  }
  return [
    TextDiffBlock(
      lines: [
        for (var i = 0; i < a.length; i++)
          TextDiffLine(
            kind: TextDiffKind.removed,
            text: a[i],
            localLine: i + 1,
          ),
        for (var j = 0; j < b.length; j++)
          TextDiffLine(
            kind: TextDiffKind.added,
            text: b[j],
            remoteLine: j + 1,
          ),
      ],
      isConflict: true,
      localLines: a,
      remoteLines: b,
    ),
  ];
}

List<TextDiffBlock> _groupBlocks(List<TextDiffLine> lines) {
  final blocks = <TextDiffBlock>[];
  final current = <TextDiffLine>[];
  bool? currentIsConflict;

  void flush() {
    if (current.isEmpty) return;
    final isConflict = currentIsConflict ?? false;
    blocks.add(TextDiffBlock(
      lines: List<TextDiffLine>.unmodifiable(current),
      isConflict: isConflict,
      localLines: [
        for (final line in current)
          if (line.kind == TextDiffKind.common || line.kind == TextDiffKind.removed)
            line.text,
      ],
      remoteLines: [
        for (final line in current)
          if (line.kind == TextDiffKind.common || line.kind == TextDiffKind.added)
            line.text,
      ],
    ));
    current.clear();
  }

  for (final line in lines) {
    final isConflict = line.kind != TextDiffKind.common;
    if (currentIsConflict != null && currentIsConflict != isConflict) {
      flush();
    }
    currentIsConflict = isConflict;
    current.add(line);
  }
  flush();
  return blocks;
}
