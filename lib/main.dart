import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/time_provider.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'services/daily_review_notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AndroidAlarmManager.initialize();
  try {
    await DailyReviewNotificationService.initialize();
  } catch (e, st) {
    debugPrint('每日提醒初始化失败（不影响 App 启动）: $e\n$st');
  }
  runApp(
    ChangeNotifierProvider(
      create: (context) => TimeProvider(),
      child: const MaterialApp(home: MainScreen()),
    ),
  );
}
