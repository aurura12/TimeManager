import 'package:flutter/widgets.dart';
import 'diary_notification_service.dart';

@pragma('vm:entry-point')
Future<void> diaryAlarmCallback() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DiaryNotificationService.onReminderFired();
}
