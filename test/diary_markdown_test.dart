import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/diary_markdown.dart';

void main() {
  test('strip 只去掉 front matter，正文保持原样', () {
    const raw = '---\ntitle: G2026年3月5日\n---\n\n正文第一行  \n第二行\n';
    expect(stripDiaryFrontMatter(raw), '\n正文第一行  \n第二行\n');
  });

  test('没有 front matter 时原样返回', () {
    expect(stripDiaryFrontMatter('普通正文'), '普通正文');
  });

  test('normalize 会统一换行并去掉首尾空白', () {
    const raw = '---\ntitle: x\n---\n\r\n  正文\r\n第二行  \r\n';
    expect(normalizeDiaryBody(raw), '正文\n第二行');
  });

  test('front matter 未闭合时不当作头信息', () {
    expect(stripDiaryFrontMatter('---\n没有结束'), '---\n没有结束');
  });
}
