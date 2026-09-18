enum AppLogLevel {
  info,
  warning,
  error,
}

extension AppLogLevelDetails on AppLogLevel {
  String get wireName => switch (this) {
        AppLogLevel.info => 'info',
        AppLogLevel.warning => 'warning',
        AppLogLevel.error => 'error',
      };

  String get label => switch (this) {
        AppLogLevel.info => '信息',
        AppLogLevel.warning => '警告',
        AppLogLevel.error => '错误',
      };

  static AppLogLevel fromWireName(String value) => switch (value) {
        'info' => AppLogLevel.info,
        'warning' => AppLogLevel.warning,
        'error' => AppLogLevel.error,
        _ => throw FormatException('未知日志级别: $value'),
      };
}

class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.error,
    this.stackTrace,
    this.dedupeKey,
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String source;
  final String message;
  final String? error;
  final String? stackTrace;

  /// 幂等键。用于导入原生事件时避免重复写入；为 null 表示普通日志。
  final String? dedupeKey;

  DateTime get localTimestamp => timestamp.toLocal();

  Map<String, dynamic> toJson() {
    return {
      'v': 1,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'level': level.wireName,
      'source': source,
      'message': message,
      if (error != null) 'error': error,
      if (stackTrace != null) 'stackTrace': stackTrace,
      // 空值不序列化，旧日志文件保持不变
      if (dedupeKey != null) 'dedupeKey': dedupeKey,
    };
  }

  factory AppLogEntry.fromJson(Map<String, dynamic> json) {
    final timestampValue = json['timestamp'];
    final levelValue = json['level'];
    final sourceValue = json['source'];
    final messageValue = json['message'];

    if (timestampValue is! String || levelValue is! String) {
      throw const FormatException('日志缺少有效的时间或级别');
    }
    if (sourceValue is! String || messageValue is! String) {
      throw const FormatException('日志缺少有效的来源或消息');
    }

    final parsedTimestamp = DateTime.tryParse(timestampValue);
    if (parsedTimestamp == null) {
      throw FormatException('日志时间无效: $timestampValue');
    }

    return AppLogEntry(
      timestamp: parsedTimestamp.toUtc(),
      level: AppLogLevelDetails.fromWireName(levelValue),
      source: sourceValue,
      message: messageValue,
      error: json['error'] is String ? json['error'] as String : null,
      stackTrace:
          json['stackTrace'] is String ? json['stackTrace'] as String : null,
      // 旧日志没有这个字段，缺失即为 null
      dedupeKey: json['dedupeKey'] is String ? json['dedupeKey'] as String : null,
    );
  }
}
