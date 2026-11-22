import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/lunar_day_label.dart';

void main() {
  setUp(clearLunarDayLabelCache);
  tearDown(clearLunarDayLabelCache);

  group('农历文案', () {
    // 期望值来自公开发布的公农历对照（含节气日期），不依赖 lunar 包的输出，
    // 包数据变化或判断顺序被改坏时这些用例会直接失败。
    test('普通农历日、初一、节日、节气按优先级取一个', () {
      expect(lunarDayLabel(DateTime(2025, 7, 25)).text, '闰六月');
      expect(lunarDayLabel(DateTime(2026, 2, 17)).text, '春节');
      expect(lunarDayLabel(DateTime(2026, 9, 23)).text, '秋分');
      expect(lunarDayLabel(DateTime(2026, 9, 25)).text, '中秋节');
      expect(lunarDayLabel(DateTime(2026, 10, 1)).text, '国庆节');
      expect(lunarDayLabel(DateTime(2026, 10, 10)).text, '九月');
      expect(lunarDayLabel(DateTime(2026, 10, 15)).text, '初六');
      expect(lunarDayLabel(DateTime(2026, 10, 18)).text, '重阳节');
      expect(lunarDayLabel(DateTime(2026, 10, 23)).text, '霜降');
      expect(lunarDayLabel(DateTime(2026, 12, 9)).text, '冬月');
    });

    test('节日与节气标记为强调，普通日子与初一不强调', () {
      expect(lunarDayLabel(DateTime(2026, 10, 18)).emphasized, isTrue);
      expect(lunarDayLabel(DateTime(2026, 10, 23)).emphasized, isTrue);
      expect(lunarDayLabel(DateTime(2026, 10, 1)).emphasized, isTrue);
      expect(lunarDayLabel(DateTime(2026, 10, 15)).emphasized, isFalse);
      expect(lunarDayLabel(DateTime(2026, 10, 10)).emphasized, isFalse);
    });

    test('语义文案保留完整农历日期和节日名', () {
      final label = lunarDayLabel(DateTime(2026, 10, 18));
      expect(label.semanticText, contains('农历九月初九'));
      expect(label.semanticText, contains('重阳节'));
      expect(lunarDayLabel(DateTime(2026, 10, 10)).semanticText, '农历九月初一');
    });

    test('同一天的不同时刻结果一致', () {
      final day = lunarDayLabel(DateTime(2026, 10, 15));
      final lateNight = lunarDayLabel(DateTime(2026, 10, 15, 23, 59, 59));
      expect(lateNight.text, day.text);
      expect(lateNight.semanticText, day.semanticText);
      expect(DateTime.utc(2026, 10, 15).month, 10);
      expect(lunarDayLabel(DateTime.utc(2026, 10, 15)).text, day.text,
          reason: '按年月日字段换算，UTC 实例不额外做时区偏移');
    });

    test('批量取文案按日期去重', () {
      final labels = lunarDayLabelsForDates([
        DateTime(2026, 10, 15),
        DateTime(2026, 10, 15, 18),
        DateTime(2026, 10, 18),
      ]);
      expect(labels.keys, unorderedEquals(['2026-10-15', '2026-10-18']));
      expect(labels['2026-10-15']!.text, '初六');
      expect(labels['2026-10-18']!.text, '重阳节');
    });

    test('缓存不改变结果', () {
      final first = lunarDayLabel(DateTime(2026, 9, 25));
      final second = lunarDayLabel(DateTime(2026, 9, 25));
      expect(identical(first, second), isTrue);
      expect(second.text, '中秋节');
    });
  });
}
