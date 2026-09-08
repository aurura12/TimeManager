import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/widgets/profile_settings_drawer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mobile settings keeps the manual identity entry visible in Google mode',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        AppIdentityService.modeKey: 'google',
        AppIdentityService.legacySyncKey: true,
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );

      final provider = TimeProvider(
        identityModePlatformOverride: true,
        googleCalendarSyncPlatformOverride: true,
      );
      addTearDown(provider.dispose);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel(
            'plugins.it_nomads.com/flutter_secure_storage',
          ),
          null,
        );
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: provider),
            ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
          ],
          child: MaterialApp(
            home: Scaffold(
              drawer: ProfileSettingsDrawer(
                onChanged: () {},
                desktopPlatformOverride: false,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (!provider.isInitialLoadFinished &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();

      final scaffoldState = tester.state<ScaffoldState>(
        find.byType(Scaffold),
      );
      scaffoldState.openDrawer();
      await tester.pump();

      expect(find.text('手动用户身份'), findsOneWidget);
      expect(find.text('乖乖'), findsOneWidget);
      expect(find.text('晶晶'), findsOneWidget);
    },
  );
}
