import 'package:flutter/services.dart';

/// 原生通知与闹钟后台插件注册（后台 isolate 可用）
class DailyReviewNative {
  static const _channel =
      MethodChannel('com.example.time_manager/daily_review');

  static Future<void> registerAlarmPlugins() async {
    try {
      await _channel.invokeMethod<void>('registerAlarmPlugins');
    } catch (_) {
      // 后台引擎尚未就绪时可能失败，闹钟触发前会再次尝试
    }
  }

  static Future<bool> showNotification({
    required String title,
    required String body,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'showNotification',
        {'title': title, 'body': body},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
