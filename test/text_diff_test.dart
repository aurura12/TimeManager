import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/text_diff.dart';

List<HunkChoice> _choices(List<TextDiffBlock> blocks, HunkChoice choice) {
  return [
    for (final block in blocks)
      if (block.isConflict) choice,
  ];
}

void main() {
  test('完全相同的正文只有一个相同块', () {
    final blocks = buildDiffBlocks('第一行\n第二行', '第一行\n第二行');
    expect(blocks, hasLength(1));
    expect(blocks.single.isConflict, isFalse);
    expect(mergeDiffBlocks(blocks, const []), '第一行\n第二行');
  });

  test('纯新增：用远端得到新内容，两边都留也能保留新增', () {
    final blocks = buildDiffBlocks('第一行', '第一行\n第二行');
    expect(blocks.where((b) => b.isConflict), hasLength(1));

    final remote = mergeDiffBlocks(blocks, _choices(blocks, HunkChoice.remote));
    expect(remote, '第一行\n第二行');

    final both = mergeDiffBlocks(blocks, _choices(blocks, HunkChoice.both));
    expect(both, '第一行\n第二行');
  });

  test('纯删除：用本地保留旧内容，用远端移除该行', () {
    final blocks = buildDiffBlocks('第一行\n第二行', '第一行');
    expect(
      mergeDiffBlocks(blocks, _choices(blocks, HunkChoice.local)),
      '第一行\n第二行',
    );
    expect(
      mergeDiffBlocks(blocks, _choices(blocks, HunkChoice.remote)),
      '第一行',
    );
  });

  test('中间替换：三种选择分别得到本地、远端与两边都留', () {
    final blocks = buildDiffBlocks('a\nb\nc', 'a\nx\nc');
    expect(blocks, hasLength(3));
    expect(blocks[1].isConflict, isTrue);
    expect(blocks[1].localLines, ['b']);
    expect(blocks[1].remoteLines, ['x']);

    expect(
      mergeDiffBlocks(blocks, _choices(blocks, HunkChoice.local)),
      'a\nb\nc',
    );
    expect(
      mergeDiffBlocks(blocks, _choices(blocks, HunkChoice.remote)),
      'a\nx\nc',
    );
    expect(
      mergeDiffBlocks(blocks, _choices(blocks, HunkChoice.both)),
      'a\nb\nx\nc',
    );
  });

  test('每个差异块可以单独选择', () {
    final blocks = buildDiffBlocks('a1\nmid\na2', 'b1\nmid\nb2');
    expect(blocks.where((b) => b.isConflict), hasLength(2));

    // 第一块选本地、第二块选远端
    expect(mergeDiffBlocks(blocks, [HunkChoice.local, HunkChoice.remote]),
        'a1\nmid\nb2');
  });

  test('CRLF 与行尾空白不算差异', () {
    final blocks = buildDiffBlocks('第一行\r\n第二行  ', '第一行\n第二行');
    expect(blocks.every((b) => !b.isConflict), isTrue);
    // 展示与输出保留本地原文（含行尾空格），只有比较忽略它。
    expect(mergeDiffBlocks(blocks, const []), '第一行\n第二行  ');
  });

  test('空正文与有内容视为整块新增', () {
    final blocks = buildDiffBlocks('', '一段内容');
    expect(blocks, hasLength(1));
    expect(blocks.single.isConflict, isTrue);
    expect(
      mergeDiffBlocks(blocks, _choices(blocks, HunkChoice.remote)),
      '一段内容',
    );
  });

  test('超长文本退化为单块，不抛异常', () {
    final identical = List<String>.filled(1001, '同一行').join('\n');
    final sameBlocks = buildDiffBlocks(identical, identical);
    expect(sameBlocks, hasLength(1));
    expect(sameBlocks.single.isConflict, isFalse);

    final left = List<String>.filled(1001, '本地').join('\n');
    final right = List<String>.filled(1001, '远端').join('\n');
    final hugeBlocks = buildDiffBlocks(left, right);
    expect(hugeBlocks, hasLength(1));
    expect(hugeBlocks.single.isConflict, isTrue);
    expect(
      mergeDiffBlocks(hugeBlocks, _choices(hugeBlocks, HunkChoice.remote)),
      right,
    );
  });

  test('默认选择是每个差异块都保留两边', () {
    final blocks = buildDiffBlocks('a\nb', 'a\nx');
    expect(defaultHunkChoices(blocks), [HunkChoice.both]);
  });
}
