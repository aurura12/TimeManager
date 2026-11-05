import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_block_reminder.dart';

void main() {
  group('TimeBlockReminderSettings', () {
    test('默认关闭并提前 5 分钟', () {
      const settings = TimeBlockReminderSettings.defaults();
      expect(settings.enabled, isFalse);
      expect(settings.leadMinutes, 5);
      expect(settings.leadLabel, '提前 5 分钟');
    });

    test('提前 0 分钟显示为准点', () {
      const settings = TimeBlockReminderSettings(
        enabled: true,
        leadMinutes: 0,
      );
      expect(settings.leadLabel, '准点');
    });

    test('快捷档位覆盖 0–30', () {
      expect(TimeBlockReminderSettings.quickLeadOptions, [0, 5, 10, 15, 20, 25, 30]);
    });

    test('自定义范围是 0–30', () {
      expect(TimeBlockReminderSettings.isValidLead(0), isTrue);
      expect(TimeBlockReminderSettings.isValidLead(30), isTrue);
      expect(TimeBlockReminderSettings.isValidLead(31), isFalse);
      expect(TimeBlockReminderSettings.isValidLead(-1), isFalse);
    });

    test('copyWith 与相等判断', () {
      const base = TimeBlockReminderSettings(enabled: false, leadMinutes: 5);
      expect(base.copyWith(enabled: true),
          const TimeBlockReminderSettings(enabled: true, leadMinutes: 5));
      expect(base, const TimeBlockReminderSettings(enabled: false, leadMinutes: 5));
      expect(base == base.copyWith(leadMinutes: 10), isFalse);
    });
  });

  group('TimeBlockReminderTap', () {
    test('解析正常 payload', () {
      final tap = TimeBlockReminderTap.tryParse('time_block_reminder:2026-11-05:84');
      expect(tap, isNotNull);
      expect(tap!.dateKey, '2026-11-05');
      expect(tap.startIndex, 84);
      expect(tap.date, DateTime(2026, 11, 5));
    });

    test('前缀、段数与索引不合法时返回 null', () {
      expect(TimeBlockReminderTap.tryParse('diary_reminder'), isNull);
      expect(TimeBlockReminderTap.tryParse('time_block_reminder:2026-11-05'), isNull);
      expect(TimeBlockReminderTap.tryParse('time_block_reminder:2026-11-05:abc'), isNull);
      expect(TimeBlockReminderTap.tryParse('time_block_reminder:2026-11-05:200'), isNull);
      expect(TimeBlockReminderTap.tryParse('time_block_reminder:2026-13-05:12'), isNull);
    });
  });

  group('TimeBlockReminderFiredRecord', () {
    test('JSON 往返', () {
      const record = TimeBlockReminderFiredRecord(
        signature: '54|59|会议|cat',
        fireAtEpochMs: 1762300800000,
        catchUp: true,
      );
      expect(TimeBlockReminderFiredRecord.tryParse(record.toJson()), record);
    });

    test('坏数据返回 null', () {
      expect(TimeBlockReminderFiredRecord.tryParse(null), isNull);
      expect(TimeBlockReminderFiredRecord.tryParse({'sig': 'x'}), isNull);
    });
  });
}
