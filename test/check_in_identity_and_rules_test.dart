import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/check_in_document.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/check_in_record.dart';
import 'package:time_manager/models/known_google_users.dart';
import 'package:time_manager/services/check_in_sync_service.dart';

const _guaiEmail = KnownGoogleUsers.guaiGuaiEmail;
const _jingEmail = KnownGoogleUsers.jingJingEmail;

CheckInGoal _goal({
  String id = 'g1',
  String ownerId = 'manual-g',
  String ownerEmail = _guaiEmail,
  DateTime? startDate,
  DateTime? endDate,
  bool archived = false,
  int targetCount = 1,
  List<CheckInRecord> records = const [],
}) {
  return CheckInGoal(
    id: id,
    ownerId: ownerId,
    ownerEmail: ownerEmail,
    name: '运动',
    description: '',
    color: const Color(0xFF000000),
    icon: Icons.flag,
    period: CheckInPeriod.daily,
    targetCount: targetCount,
    records: records,
    requirePhoto: false,
    requireLocation: false,
    startDate: startDate,
    endDate: endDate,
    isArchived: archived,
  );
}

CheckInRecord _record({
  String id = 'r1',
  String goalId = 'g1',
  String userId = 'google-sub-g',
  String email = _guaiEmail,
  DateTime? timestamp,
}) {
  return CheckInRecord(
    id: id,
    goalId: goalId,
    userId: userId,
    userEmail: email,
    timestamp: timestamp ?? DateTime(2026, 9, 14, 9),
  );
}

void main() {
  group('打卡逻辑身份归一化', () {
    test('手动身份和 Google 身份按邮箱视为同一用户', () {
      final now = DateTime.now();
      final goal = _goal(
        records: [_record(timestamp: now)],
      );

      expect(goal.isOwnedBy('google-sub-g', email: _guaiEmail), isTrue);
      expect(goal.isOwnedBy('manual-g', email: _guaiEmail), isTrue);
      expect(
        goal.currentPeriodCountFor('manual-g', email: _guaiEmail),
        1,
      );
      expect(
        goal.isCompletedTodayBy('manual-g', email: _guaiEmail),
        isTrue,
      );
      expect(
        goal.streakDaysFor('manual-g', email: _guaiEmail),
        1,
      );
      expect(goal.currentPeriodCountFor('google-sub-g', email: _guaiEmail), 1);
    });

    test('全部筛选下目标进度仍按目标所有者统计，不混算另一用户', () {
      final now = DateTime.now();
      final goal = _goal(
        targetCount: 2,
      ).copyWith(
        records: [
          _record(id: 'g-record', timestamp: now),
          _record(
            id: 'j-record',
            userId: 'google-sub-j',
            email: _jingEmail,
            timestamp: now,
          ),
        ],
      );

      expect(
        goal.currentPeriodCountFor(goal.ownerId, email: goal.ownerEmail),
        1,
      );
      expect(goal.currentPeriodCountFor(null), 2);
      expect(
        goal.progressFor(goal.ownerId, email: goal.ownerEmail),
        0.5,
      );
    });

    test('同一邮箱的跨身份记录会被重复打卡校验识别', () {
      final goal = _goal();
      final error = CheckInSyncService.validateCheckInRequest(
        goal: goal,
        existingRecords: [
          _record(
            userId: 'google-sub-g',
            timestamp: DateTime(2026, 9, 14, 8),
          ),
        ],
        userId: 'manual-g',
        userEmail: _guaiEmail,
        now: DateTime(2026, 9, 14, 12),
        backfillDate: DateTime(2026, 9, 14, 7),
      );

      expect(error, '这一天已经打卡，不能重复补打卡');
    });
  });

  group('打卡目标生命周期与服务层规则', () {
    test('未来目标不活跃，开始日当天允许打卡', () {
      final today = DateTime.now();
      final todayOnly = DateTime(today.year, today.month, today.day);
      final start = todayOnly.add(const Duration(days: 1));
      final goal = _goal(
        startDate: start,
        endDate: start.add(const Duration(days: 5)),
      );

      expect(goal.isNotStartedAt(todayOnly.add(const Duration(hours: 23))),
          isTrue);
      expect(goal.isActive, isFalse);
      expect(goal.allowsCheckInAt(start), isTrue);
    });

    test('结束日期当天允许打卡，结束日之后拒绝', () {
      final goal = _goal(
        startDate: DateTime(2026, 9, 10),
        endDate: DateTime(2026, 9, 14),
      );

      expect(
        CheckInSyncService.validateCheckInRequest(
          goal: goal,
          existingRecords: const [],
          userId: 'manual-g',
          userEmail: _guaiEmail,
          now: DateTime(2026, 9, 14, 23),
        ),
        isNull,
      );
      expect(
        CheckInSyncService.validateCheckInRequest(
          goal: goal,
          existingRecords: const [],
          userId: 'manual-g',
          userEmail: _guaiEmail,
          now: DateTime(2026, 9, 15),
        ),
        '已超过目标结束日期，不能打卡',
      );
    });

    test('服务层拒绝开始日前补打卡和未来日期', () {
      final goal = _goal(
        startDate: DateTime(2026, 9, 15),
        endDate: DateTime(2026, 9, 20),
      );
      const userId = 'manual-g';

      expect(
        CheckInSyncService.validateCheckInRequest(
          goal: goal,
          existingRecords: const [],
          userId: userId,
          userEmail: _guaiEmail,
          now: DateTime(2026, 9, 16),
          backfillDate: DateTime(2026, 9, 14),
        ),
        '目标尚未开始，不能打卡',
      );
      expect(
        CheckInSyncService.validateCheckInRequest(
          goal: goal,
          existingRecords: const [],
          userId: userId,
          userEmail: _guaiEmail,
          now: DateTime(2026, 9, 14),
          backfillDate: DateTime(2026, 9, 15),
        ),
        '不能补打未来日期',
      );
    });

    test('服务层拒绝修改或打卡到其他用户的目标', () {
      final otherGoal = _goal(
        ownerId: 'manual-j',
        ownerEmail: _jingEmail,
      );

      expect(
        CheckInSyncService.validateGoalMutation(
          goal: otherGoal,
          document: CheckInDocument.empty,
          userId: 'manual-g',
          userEmail: _guaiEmail,
        ),
        '目标归属与当前身份不一致',
      );
      expect(
        CheckInSyncService.validateCheckInRequest(
          goal: otherGoal,
          existingRecords: const [],
          userId: 'manual-g',
          userEmail: _guaiEmail,
          now: DateTime(2026, 9, 14),
        ),
        '只能在自己的目标下打卡',
      );
    });

    test('归档恢复可以清空 archivedAt', () {
      final archived = _goal(archived: true).copyWith(
        archivedAt: DateTime(2026, 9, 14),
      );
      final restored = archived.copyWith(isArchived: false, archivedAt: null);

      expect(restored.isArchived, isFalse);
      expect(restored.archivedAt, isNull);
    });
  });
}
