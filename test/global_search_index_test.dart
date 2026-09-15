import 'package:flutter_test/flutter_test.dart';

import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/global_search_result.dart';

void main() {
  test('GlobalSearchIndex 按模块、身份和日期筛选并限制数量', () {
    final index = GlobalSearchIndex([
      GlobalSearchResult(
        type: GlobalSearchContentType.diary,
        date: DateTime(2026, 9, 14),
        title: '乖乖日记',
        summary: '阅读和散步',
        identityKind: DiaryKind.g,
      ),
      GlobalSearchResult(
        type: GlobalSearchContentType.travel,
        date: DateTime(2026, 9, 13),
        title: '上海',
        summary: '参加阅读会议',
      ),
      GlobalSearchResult(
        type: GlobalSearchContentType.target,
        date: DateTime(2026, 8, 1),
        title: '阅读计划',
        summary: '时长目标',
        identityKind: DiaryKind.j,
      ),
    ]);

    expect(index.search('阅读'), hasLength(3));
    expect(
      index
          .search(
            '阅读',
            contentType: GlobalSearchContentType.diary,
            identity: GlobalSearchIdentityFilter.guaiGuai,
          )
          .map((result) => result.title),
      ['乖乖日记'],
    );
    expect(
      index
          .search(
            '阅读',
            startDate: DateTime(2026, 9, 1),
            endDate: DateTime(2026, 9, 30),
          )
          .map((result) => result.title),
      ['乖乖日记', '上海'],
    );
    expect(index.search('阅读', limit: 1), hasLength(1));
  });

  test('没有日期的元数据在日期筛选下不被错误归属', () {
    final index = GlobalSearchIndex([
      GlobalSearchResult(
        type: GlobalSearchContentType.target,
        date: null,
        title: '无日期目标',
        summary: '本地目标',
      ),
    ]);

    expect(index.search('目标'), hasLength(1));
    expect(index.search('目标', startDate: DateTime(2026, 9, 1)), isEmpty);
  });
}
