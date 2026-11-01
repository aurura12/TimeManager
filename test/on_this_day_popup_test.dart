import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/background_image_provider.dart';
import 'package:time_manager/providers/main_tab_provider.dart';
import 'package:time_manager/providers/on_this_day_popup_provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/widgets/profile_settings_drawer.dart';

void _installPluginMocks(Map<String, Object> initialPreferences) {
  SharedPreferences.setMockInitialValues(initialPreferences);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_on_this_day_popup_test',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OnThisDayPopupProvider', () {
    test('默认自动弹出', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = OnThisDayPopupProvider();
      await provider.ready;
      expect(provider.autoShow, isTrue);
    });

    test('关闭后落盘，重新读取仍是关闭', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = OnThisDayPopupProvider();
      await provider.ready;
      await provider.setAutoShow(false);
      expect(provider.autoShow, isFalse);

      final reloaded = OnThisDayPopupProvider();
      await reloaded.ready;
      expect(reloaded.autoShow, isFalse, reason: '开关要能跨启动保留');
    });

    test('脏数据回落为自动弹出', () async {
      SharedPreferences.setMockInitialValues(
        {OnThisDayPopupProvider.storageKey: 'not-a-bool'},
      );
      final provider = OnThisDayPopupProvider();
      await provider.ready;
      expect(provider.autoShow, isTrue);
    });

    test('落盘失败回滚并抛出', () async {
      final provider = OnThisDayPopupProvider(
        preferencesLoader: () async => _FailingPreferences(),
      );
      await provider.ready;
      await expectLater(provider.setAutoShow(false), throwsA(anything));
      expect(provider.autoShow, isTrue, reason: '保存失败不能显示成已关闭');
    });
  });

  testWidgets('设置里可以关闭「自动弹出」并落盘', (tester) async {
    _installPluginMocks({});
    final provider = TimeProvider();
    addTearDown(provider.dispose);
    final popup = OnThisDayPopupProvider();
    await popup.ready;
    addTearDown(popup.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
          ChangeNotifierProvider(create: (_) => BackgroundImageProvider()),
          ChangeNotifierProvider(create: (_) => MainTabProvider()),
          ChangeNotifierProvider<OnThisDayPopupProvider?>.value(value: popup),
        ],
        child: MaterialApp(
          home: Scaffold(
            drawer: ProfileSettingsDrawer(
              onChanged: () {},
              desktopPlatformOverride: false,
              androidPlatformOverride: false,
            ),
          ),
        ),
      ),
    );

    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffoldState.openDrawer();
    await tester.pumpAndSettle();

    await tester.tap(find.text('记录回顾'));
    await tester.pumpAndSettle();

    expect(find.text('自动弹出'), findsOneWidget);
    expect(find.text('打开应用时自动回顾往年今天的记录'), findsOneWidget);
    expect(popup.autoShow, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(popup.autoShow, isFalse);
    expect(find.text('只在上面手动查看'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(OnThisDayPopupProvider.storageKey), isFalse,
        reason: '开关要落盘，下次启动不再自动弹');
  });

  testWidgets('没有注册 Provider 的宿主不显示该开关', (tester) async {
    _installPluginMocks({});
    final provider = TimeProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
          ChangeNotifierProvider(create: (_) => BackgroundImageProvider()),
          ChangeNotifierProvider(create: (_) => MainTabProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            drawer: ProfileSettingsDrawer(
              onChanged: () {},
              desktopPlatformOverride: false,
              androidPlatformOverride: false,
            ),
          ),
        ),
      ),
    );

    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffoldState.openDrawer();
    await tester.pumpAndSettle();

    await tester.tap(find.text('记录回顾'));
    await tester.pumpAndSettle();

    expect(find.text('那年今日'), findsOneWidget);
    expect(find.text('自动弹出'), findsNothing);
  });
}

/// 写操作都失败的偏好实现，用来验证回滚。
class _FailingPreferences implements SharedPreferences {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('get')) return null;
    if (name.contains('set')) return false;
    return null;
  }
}
