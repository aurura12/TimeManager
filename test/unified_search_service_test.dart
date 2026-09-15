import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:time_manager/models/check_in_document.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/check_in_record.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/global_search_result.dart';
import 'package:time_manager/models/travel_record.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/unified_search_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  test('统一索引支持内容、身份、日期筛选并限制返回数量', () {
    final index = GlobalSearchIndex([
      GlobalSearchResult(
        type: GlobalSearchContentType.diary,
        date: DateTime(2026, 9, 14),
        title: '乖乖日记',
        summary: '记录了阅读和散步',
        identityKind: DiaryKind.g,
      ),
      GlobalSearchResult(
        type: GlobalSearchContentType.travel,
        date: DateTime(2026, 9, 13),
        title: '上海',
        summary: '地点：上海 · 事件：参加会议',
      ),
      GlobalSearchResult(
        type: GlobalSearchContentType.target,
        date: DateTime(2026, 9, 12),
        title: '阅读计划',
        summary: '时长目标 1 小时',
        identityKind: DiaryKind.j,
      ),
      GlobalSearchResult(
        type: GlobalSearchContentType.diary,
        date: DateTime(2026, 8, 1),
        title: '晶晶日记',
        summary: '记录了阅读',
        identityKind: DiaryKind.j,
      ),
    ]);

    expect(
      index.search('阅读'),
      hasLength(3),
    );
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
      ['乖乖日记', '阅读计划'],
    );
    expect(
      index.search('阅读', limit: 1),
      hasLength(1),
    );
  });

  test('服务只读取注入的本地出行和打卡数据', () async {
    var travelReads = 0;
    var checkInReads = 0;
    final travel = TravelRecordsDocument(
      records: [
        TravelRecord(
          date: DateTime(2026, 9, 14),
          location: '杭州西湖',
          event: '散步',
        ),
      ],
    );
    final goal = CheckInGoal(
      id: 'goal-1',
      ownerId: 'manual-g',
      ownerEmail: 'zjq031115a@gmail.com',
      name: '晨跑',
      description: '每天跑步',
      color: Colors.green,
      icon: Icons.directions_run,
      period: CheckInPeriod.daily,
      targetCount: 1,
      updatedAt: DateTime(2026, 9, 14).millisecondsSinceEpoch,
    );
    final checkIn = CheckInDocument(
      goals: [goal],
      records: [
        CheckInRecord(
          id: 'record-1',
          goalId: goal.id,
          userId: goal.ownerId,
          userEmail: goal.ownerEmail,
          timestamp: DateTime(2026, 9, 14, 7),
          locationName: '西湖边',
          note: '天气很好',
        ),
      ],
    );

    final service = UnifiedSearchService(
      preferencesLoader: SharedPreferences.getInstance,
      travelLoader: () async {
        travelReads++;
        return travel;
      },
      checkInLoader: () async {
        checkInReads++;
        return checkIn;
      },
    );

    final travelResults = await service.search('西湖');
    final travelOnlyResults = await service.search(
      '西湖',
      contentType: GlobalSearchContentType.travel,
    );
    final checkInResults = await service.search(
      '天气',
      contentType: GlobalSearchContentType.checkIn,
      identity: GlobalSearchIdentityFilter.guaiGuai,
    );

    expect(travelResults, hasLength(2));
    expect(travelOnlyResults, hasLength(1));
    expect(travelOnlyResults.single.type, GlobalSearchContentType.travel);
    expect(travelOnlyResults.single.summary, contains('杭州西湖'));
    expect(checkInResults.single.title, '晨跑');
    expect(checkInResults.single.summary, contains('天气很好'));
    expect(travelReads, 1);
    expect(checkInReads, 1);
  });

  test('无日期的元数据在日期筛选下不会被错误归属', () {
    final index = GlobalSearchIndex([
      GlobalSearchResult(
        type: GlobalSearchContentType.target,
        date: null,
        title: '无日期目标',
        summary: '本地目标',
      ),
    ]);

    expect(index.search('目标'), hasLength(1));
    expect(
      index.search('目标', startDate: DateTime(2026, 9, 1)),
      isEmpty,
    );
  });
}
