import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/check_in_document.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/check_in_record.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/check_in_sync_service.dart';

CheckInGoal _goal(String id) {
  return CheckInGoal(
    id: id,
    ownerId: 'uid-$id',
    ownerEmail: 'test@example.com',
    ownerDisplayName: 'T',
    name: '目标$id',
    description: '',
    color: const Color(0xFF000000),
    icon: Icons.flag,
    period: CheckInPeriod.daily,
    targetCount: 1,
  );
}

CheckInRecord _record(String id, String goalId, DateTime ts) {
  return CheckInRecord(
    id: id,
    goalId: goalId,
    userId: 'uid',
    userEmail: 'test@example.com',
    timestamp: ts,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });
  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  group('CheckInDocument.reviveRecord', () {
    test('恢复记录并清除该 id 的墓碑', () {
      final goal = _goal('g1');
      final record = _record('r1', 'g1', DateTime(2026, 10, 1, 8));
      final other = _record('r2', 'g1', DateTime(2026, 10, 2, 8));

      final deleted =
          CheckInDocument(goals: [goal], records: [other, record])
              .tombstoneRecord('r1');
      expect(deleted.records.map((r) => r.id), ['r2']);
      expect(deleted.deletedRecordIds, {'r1'});

      final revived = deleted.reviveRecord(record);
      expect(revived.records.map((r) => r.id), ['r2', 'r1']);
      expect(revived.deletedRecordIds, isEmpty);
      expect(revived.deletedGoalIds, isEmpty);
    });

    test('恢复后的文档与仍持有旧墓碑的远端合并时记录不会被本地复活判断误杀',
        () {
      // 本机推送的恢复文档不含墓碑；只要远端文档也已被覆盖为无墓碑版本，
      // 后续 pull-merge 记录稳定存活。
      final goal = _goal('g1');
      final record = _record('r1', 'g1', DateTime(2026, 10, 1, 8));
      final revived = CheckInDocument(goals: [goal], records: const [])
          .reviveRecord(record);

      final remotePushedBack =
          CheckInDocument.fromMarkdown(revived.toMarkdown());
      final merged = CheckInDocument.merge(revived, remotePushedBack);
      expect(merged.records.map((r) => r.id), contains('r1'));
      expect(merged.deletedRecordIds, isEmpty);
    });

    test('另一台设备仍持有旧墓碑时，其合并结果不复活该记录（撤销的固有边界）',
        () {
      final goal = _goal('g1');
      final record = _record('r1', 'g1', DateTime(2026, 10, 1, 8));
      final revived = CheckInDocument(goals: [goal], records: [record]);
      final staleDevice = CheckInDocument(
        goals: [goal],
        records: const [],
        deletedRecordIds: {'r1'},
      );

      final merged = CheckInDocument.merge(staleDevice, revived);
      expect(merged.records.map((r) => r.id), isNot(contains('r1')));
    });
  });

  group('restoreCheckInRecord 守卫', () {
    test('没有 Token 时返回离线而不是失败', () async {
      // restoreCheckInRecord 会先 AppIdentityService.load()，身份必须可持久化读回。
      SharedPreferences.setMockInitialValues({
        AppIdentityService.modeKey: 'manual',
        AppIdentityService.legacyScheduleUserKey: 'j',
      });
      await AppIdentityService.load();
      final service = CheckInSyncService(tokenLoader: () async => null);
      final result = await service.restoreCheckInRecord(
        goal: _goal('g1'),
        record: _record('r1', 'g1', DateTime(2026, 10, 1, 8)),
      );
      expect(result.offline, isTrue);
    });

    test('未选择身份时返回失败', () async {
      final service = CheckInSyncService(tokenLoader: () async => 'token');
      final result = await service.restoreCheckInRecord(
        goal: _goal('g1'),
        record: _record('r1', 'g1', DateTime(2026, 10, 1, 8)),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('请先选择'));
    });
  });
}
