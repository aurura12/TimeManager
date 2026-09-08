import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/app_log_entry.dart';

void main() {
  test('日志条目 JSON 往返保留 UTC 毫秒、级别和异常信息', () {
    final original = AppLogEntry(
      timestamp: DateTime.utc(2026, 9, 8, 12, 34, 56, 789),
      level: AppLogLevel.error,
      source: 'startup',
      message: '启动失败',
      error: 'FormatException: bad data',
      stackTrace: 'stack line 1',
    );

    final decoded = AppLogEntry.fromJson(original.toJson());

    expect(decoded.timestamp, original.timestamp);
    expect(decoded.timestamp.isUtc, isTrue);
    expect(decoded.level, AppLogLevel.error);
    expect(decoded.source, 'startup');
    expect(decoded.message, '启动失败');
    expect(decoded.error, 'FormatException: bad data');
    expect(decoded.stackTrace, 'stack line 1');
  });

  test('非法日志级别和时间会被识别为格式错误', () {
    expect(
      () => AppLogEntry.fromJson({
        'timestamp': 'not-a-date',
        'level': 'fatal',
        'source': 'test',
        'message': 'bad',
      }),
      throwsFormatException,
    );
  });
}
