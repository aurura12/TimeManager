import 'package:flutter/services.dart';

/// 原生通知与后台插件注册
class DailyReviewNative {
  static const _channel =
      MethodChannel('com.example.time_manager/daily_review');

  static Future<void> registerAlarmPlugins() async {
    try {
      await _channel.invokeMethod<void>('registerAlarmPlugins');
    } catch (_) {}
  }

  static Future<bool> showNotification({
    required String title,
    required String body,
    required String dateKey,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'showNotification',
        {
          'title': title,
          'body': body,
          'dateKey': dateKey,
        },
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> consumeLaunchReviewDate() async {
    try {
      return await _channel.invokeMethod<String>('consumeLaunchReviewDate');
    } catch (_) {
      return null;
    }
  }
}
