import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/check_in_record.dart';

CheckInGoal _goal(List<DateTime> timestamps, {String userId = 'u1'}) {
  return CheckInGoal(
    id: 'g1',
    ownerId: userId,
    ownerEmail: 'a@example.com',
    name: '运动',
    description: '',
    color: const Color(0xFF000000),
    icon: Icons.flag,
    period: CheckInPeriod.daily,
    targetCount: 1,
    records: [
      for (var i = 0; i < timestamps.length; i++)
        CheckInRecord(
          id: 'r$i',
          goalId: 'g1',
          userId: userId,
          userEmail: 'a@example.com',
          timestamp: timestamps[i],
        ),
    ],
  );
}

DateTime _daysAgo(int days, {int hour = 10}) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - days, hour);
}

void main() {
  group('streakDaysFor', () {
    test('没有记录时返回 0', () {
      expect(_goal(const []).streakDaysFor('u1'), 0);
    });

    test('只有今天打卡返回 1', () {
      expect(_goal([_daysAgo(0)]).streakDaysFor('u1'), 1);
    });

    test('今天未打卡、昨天打卡返回 1', () {
      expect(_goal([_daysAgo(1)]).streakDaysFor('u1'), 1);
    });

    test('今天和昨天都有打卡返回 2', () {
      expect(_goal([_daysAgo(0), _daysAgo(1)]).streakDaysFor('u1'), 2);
    });

    // 回归：同一天多次打卡曾因未按天去重而中断统计
    test('同一天多次打卡只算一天（今天2次+昨天1次 = 2）', () {
      final goal = _goal([
        _daysAgo(0, hour: 8),
        _daysAgo(0, hour: 20),
        _daysAgo(1),
      ]);
      expect(goal.streakDaysFor('u1'), 2);
    });

    test('连续 5 天（含今天多次打卡）返回 5', () {
      final goal = _goal([
        for (var d = 0; d < 5; d++) _daysAgo(d, hour: 9),
        for (var d = 0; d < 5; d++) _daysAgo(d, hour: 21),
      ]);
      expect(goal.streakDaysFor('u1'), 5);
    });

    test('中间断档时只计算到断档前', () {
      final goal = _goal([_daysAgo(0), _daysAgo(1), _daysAgo(3), _daysAgo(4)]);
      expect(goal.streakDaysFor('u1'), 2);
    });

    test('今天和昨天都没有打卡返回 0（即使前天有）', () {
      expect(_goal([_daysAgo(2), _daysAgo(3)]).streakDaysFor('u1'), 0);
    });

    test('只统计指定用户的记录', () {
      final goal = _goal([_daysAgo(0), _daysAgo(1)]);
      expect(goal.streakDaysFor('other'), 0);
      // 按 email 匹配同样生效
      expect(goal.streakDaysFor('nobody', email: 'a@example.com'), 2);
    });
  });
}
