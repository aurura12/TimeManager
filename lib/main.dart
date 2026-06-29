import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'providers/time_provider.dart';
import 'package:time_manager/screens/main_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  ErrorWidget.builder = (details) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text('应用遇到了问题', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(details.exceptionAsString(), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => main(),
                  child: const Text('重启应用'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

  try {
    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (context) => TimeProvider()),
          ChangeNotifierProvider(create: (context) => ThemeModeProvider()),
        ],
        child: const TimeManagerApp(),
      ),
    );
  } catch (e) {
    debugPrint('应用启动失败: $e');
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('启动失败: $e', style: const TextStyle(color: Colors.red)),
        ),
      ),
    ));
  }
}

class TimeManagerApp extends StatefulWidget {
  const TimeManagerApp({super.key});

  @override
  State<TimeManagerApp> createState() => _TimeManagerAppState();
}

class _TimeManagerAppState extends State<TimeManagerApp> {
  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<ThemeModeProvider>().themeMode;
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
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
