import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'app_log_service.dart';

final Logger _logger = Logger();

const String _source = 'feishu_calendar';

void feishuLog(String message) {
  _logger.i(message);
  debugPrint('[FeishuCalendar] $message');
  AppLogService.instance.info(message, source: _source);
}

void feishuLogWarning(
  String message, {
  Object? error,
  StackTrace? stackTrace,
}) {
  _logger.w(message, stackTrace: stackTrace);
  AppLogService.instance.warning(
    message,
    source: _source,
    error: error,
    stackTrace: stackTrace,
  );
}

void feishuLogError(
  String message, {
  Object? error,
  StackTrace? stackTrace,
}) {
  _logger.e(message, stackTrace: stackTrace);
  AppLogService.instance.error(
    message,
    source: _source,
    error: error,
    stackTrace: stackTrace,
  );
}
