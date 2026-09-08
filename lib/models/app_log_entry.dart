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
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String source;
  final String message;
  final String? error;
  final String? stackTrace;

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
    );
  }
}
