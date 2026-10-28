import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/providers/time_provider.dart';

TimeSlot _slot({bool recorded = true, String? label = '专注'}) => TimeSlot(
      hour: 8,
      minute10: 0,
      recorded: recorded,
      label: label,
    );

void main() {
  test('空数据、空白天、墓碑和无事件名的槽位都不算记录', () {
    expect(TimeProvider.earliestRecordedDayOf(const {}), isNull);
    expect(
      TimeProvider.earliestRecordedDayOf({
        '2024-01-01': [TimeSlot(hour: 0, minute10: 0)],
        '2024-02-01': [
          TimeSlot(
            hour: 0,
            minute10: 0,
            deletedAt: DateTime(2024, 2, 1),
          ),
        ],
        '2024-03-01': [_slot(label: null)],
      }),
      isNull,
    );
  });

  test('返回最早的有记录日期，兼容旧的不补零 key 与坏 key', () {
    final earliest = TimeProvider.earliestRecordedDayOf({
      '2026-10-28': [_slot()],
      '2024-7-24': [_slot()],
      '2025-01-05': [_slot(recorded: false, label: null)],
      'bad-key': [_slot()],
    });

    expect(earliest, DateTime(2024, 7, 24));
  });

  test('同一天有记录与无记录的列表混排时仍取有记录的那天', () {
    final earliest = TimeProvider.earliestRecordedDayOf({
      '2023-12-31': [TimeSlot(hour: 23, minute10: 5)],
      '2024-01-01': [
        TimeSlot(hour: 0, minute10: 0),
        TimeSlot(
          hour: 8,
          minute10: 0,
          recorded: true,
          label: '起床',
        ),
      ],
    });

    expect(earliest, DateTime(2024, 1, 1));
  });
}
