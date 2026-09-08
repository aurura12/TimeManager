import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/main.dart';
import 'package:time_manager/models/app_log_entry.dart';
import 'package:time_manager/services/app_log_service.dart';

import 'support/fake_app_log_store.dart';

void main() {
  test('全局 Flutter 和 Dart 错误处理器会写入应用日志', () {
    final service = AppLogService(store: FakeAppLogStore());
    final previousFlutterHandler = FlutterError.onError;
    final previousPlatformHandler = PlatformDispatcher.instance.onError;
    try {
      installGlobalLogErrorHandlers(service);

      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('widget failed'),
        stack: StackTrace.current,
      ));
      final handled = PlatformDispatcher.instance.onError!(
        StateError('async failed'),
        StackTrace.current,
      );

      expect(handled, isFalse);
      expect(service.entries, hasLength(2));
      expect(service.entries[0].source, 'dart');
      expect(service.entries[0].level, AppLogLevel.error);
      expect(service.entries[1].source, 'flutter');
      expect(service.entries[1].level, AppLogLevel.error);
    } finally {
      FlutterError.onError = previousFlutterHandler;
      PlatformDispatcher.instance.onError = previousPlatformHandler;
    }
  });
}
