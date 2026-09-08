import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:time_manager/models/app_log_entry.dart';
import 'package:time_manager/services/app_log_export_service.dart';

void main() {
  test('导出文本包含本地毫秒时间、级别、来源、异常和堆栈', () {
    final entry = AppLogEntry(
      timestamp: DateTime.utc(2026, 9, 8, 1, 2, 3, 456),
      level: AppLogLevel.error,
      source: 'google_calendar',
      message: '同步失败',
      error: 'TimeoutException',
      stackTrace: 'line one',
    );

    final text = AppLogExportService.format(
      [entry],
      exportedAt: DateTime.utc(2026, 9, 8, 1, 3),
    );

    expect(text, contains('TimeManager 运行日志'));
    expect(
      text,
      contains(
          DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(entry.localTimestamp)),
    );
    expect(text, contains('[错误] [google_calendar] 同步失败'));
    expect(text, contains('异常：TimeoutException'));
    expect(text, contains('堆栈：\nline one'));
  });
}
