import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'providers/time_provider.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'services/daily_review_notification_service.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await AndroidAlarmManager.initialize();
  }
  try {
    await DailyReviewNotificationService.initialize(
      navigatorKey: rootNavigatorKey,
    );
  } catch (e, st) {
    debugPrint('每日提醒初始化失败（不影响 App 启动）: $e\n$st');
  }
  runApp(
    ChangeNotifierProvider(
      create: (context) => TimeProvider(),
      child: const TimeManagerApp(),
    ),
  );
}

class TimeManagerApp extends StatefulWidget {
  const TimeManagerApp({super.key});

  @override
  State<TimeManagerApp> createState() => _TimeManagerAppState();
}

class _TimeManagerAppState extends State<TimeManagerApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DailyReviewNotificationService.handleColdStartNavigation();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      home: const MainScreen(),
    );
  }
}
