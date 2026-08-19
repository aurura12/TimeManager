import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/services/voice_schedule_parser.dart';

void main() {
  final baseDate = DateTime(2026, 8, 19);

  test('解析带日期和下午时间的已有子事件', () {
    final category = Category(
      id: 'work',
      name: '工作',
      color: Colors.blue,
      subCategories: ['开会'],
    );

    final result = VoiceScheduleParser.parse(
      transcript: '明天下午三点到四点开会',
      baseDate: baseDate,
      categories: [category],
    );

    expect(result.isSuccess, isTrue);
    expect(result.draft!.date, DateTime(2026, 8, 20));
    expect(result.draft!.startIndex, 15 * 6);
    expect(result.draft!.endIndexExclusive, 16 * 6);
    expect(result.draft!.label, '开会');
    expect(result.draft!.categoryId, 'work');
    expect(result.draft!.isTemporary, isFalse);
  });

  test('没有日期时使用当前选中日期，并支持半小时和一小时', () {
    final category = Category(
      id: 'exercise',
      name: '运动',
      color: Colors.green,
      subCategories: ['跑步'],
    );

    final result = VoiceScheduleParser.parse(
      transcript: '上午九点半跑步一小时',
      baseDate: baseDate,
      categories: [category],
    );

    expect(result.isSuccess, isTrue);
    expect(result.draft!.date, baseDate);
    expect(result.draft!.startIndex, 9 * 6 + 3);
    expect(result.draft!.endIndexExclusive, 10 * 6 + 3);
    expect(result.draft!.label, '跑步');
    expect(result.draft!.categoryId, 'exercise');
  });

  test('找不到已有事件时保留事项名称并标记为临时事件', () {
    final result = VoiceScheduleParser.parse(
      transcript: '明天下午三点到四点去健身房',
      baseDate: baseDate,
      categories: [
        Category(id: 'work', name: '工作', color: Colors.blue),
      ],
    );

    expect(result.isSuccess, isTrue);
    expect(result.draft!.label, '去健身房');
    expect(result.draft!.categoryId, isNull);
    expect(result.draft!.isTemporary, isTrue);
  });

  test('缺少事项名称时不生成日程草稿', () {
    final result = VoiceScheduleParser.parse(
      transcript: '明天下午三点到四点',
      baseDate: baseDate,
      categories: const [],
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, contains('事项'));
  });
}
