import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/diary_remote_path_utils.dart';

void main() {
  test('远程日记路径按真实日期正序排列，而不是按文件名字典序排列', () {
    final paths = [
      'G🛹2026年9月2日.md',
      'G🛹2026年9月14日.md',
      'G🛹2026年9月10日.md',
      'G🛹2026年9月6日.md',
    ];

    paths.sort(compareDiaryRemoteFilePaths);

    expect(paths, [
      'G🛹2026年9月2日.md',
      'G🛹2026年9月6日.md',
      'G🛹2026年9月10日.md',
      'G🛹2026年9月14日.md',
    ]);
  });

  test('无法解析日期时仍使用文件名作为稳定的后备排序', () {
    final paths = [
      'J🕊️日记.md',
      'J🕊️2026年9月2日.md',
      'J🕊️2026年9月1日.md',
    ];

    paths.sort(compareDiaryRemoteFilePaths);

    expect(paths, [
      'J🕊️2026年9月1日.md',
      'J🕊️2026年9月2日.md',
      'J🕊️日记.md',
    ]);
  });

  test('支持嵌套目录，并拒绝会被 DateTime 自动归一化的非法日期', () {
    expect(
      parseDiaryDateFromRemotePath('diary/G🛹2026年9月2日.md'),
      DateTime(2026, 9, 2),
    );
    expect(
      parseDiaryDateFromRemotePath('G🛹2026年9月31日.md'),
      isNull,
    );
  });
}
