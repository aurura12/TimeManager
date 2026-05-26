import 'package:flutter/widgets.dart';
import 'daily_review_notification_service.dart';

/// 到点触发：在此 isolate 中生成 AI 总结并弹出通知
@pragma('vm:entry-point')
Future<void> dailyReviewAlarmCallback() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DailyReviewNotificationService.onReminderFired();
}
