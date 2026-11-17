import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/home_widget_appearance_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
  });

  List<Map<String, dynamic>> themePayloads() => calls
      .where((call) => call.method == 'saveWidgetData')
      .map((call) => call.arguments as Map)
      .where((args) => args['id'] == 'widget_theme')
      .map((args) => jsonDecode(args['data'] as String) as Map<String, dynamic>)
      .toList();

  int widgetUpdates() =>
      calls.where((call) => call.method == 'updateWidget').length;

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    // 让 unawaited 的通道调用落地。
    await tester.pump();
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    ThemeMode mode = ThemeMode.light,
    Color seed = AppTheme.seedColor,
    bool followsSystem = false,
    bool supported = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(seedColor: seed),
        darkTheme: AppTheme.dark(seedColor: seed),
        themeMode: mode,
        builder: (context, child) => HomeWidgetAppearanceSync(
          seedColor: seed,
          followsSystem: followsSystem,
          supported: supported,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const SizedBox.shrink(),
      ),
    );
    await settle(tester);
  }

  testWidgets('冷启动推一次外观，mode 与当前亮度一致', (tester) async {
    await pumpHost(tester);

    final payloads = themePayloads();
    expect(payloads, hasLength(1));
    expect(payloads.single['mode'], 'light');
    expect(payloads.single['sys'], isFalse);
    expect(widgetUpdates(), 1);
  });

  testWidgets('无关重建不会重复推送', (tester) async {
    await pumpHost(tester);
    final before = themePayloads().length;

    await pumpHost(tester);

    expect(themePayloads(), hasLength(before));
    expect(widgetUpdates(), before);
  });

  testWidgets('切到深色只推一次，且不会被 AnimatedTheme 逐帧带偏', (tester) async {
    await pumpHost(tester);
    final before = themePayloads().length;

    await pumpHost(tester, mode: ThemeMode.dark);

    final payloads = themePayloads();
    expect(payloads, hasLength(before + 1));
    expect(payloads.last['mode'], 'dark');
    expect(payloads.last['sys'], isFalse);
    // 浅色那套仍然随包下发，供 App 未运行时被系统选中。
    expect(payloads.last['light'], isA<Map>());
    expect(widgetUpdates(), before + 1);
  });

  testWidgets('改主题色会重推，而且按钮色真的变了', (tester) async {
    await pumpHost(tester);
    final before = themePayloads();

    await pumpHost(tester, seed: AppThemeColorPreset.rose.color);

    final payloads = themePayloads();
    expect(payloads, hasLength(before.length + 1));
    final previousAction = (before.last['light'] as Map)['actionBg'] as int;
    final currentAction = (payloads.last['light'] as Map)['actionBg'] as int;
    expect(currentAction, isNot(previousAction));
    // 语义色不跟主题色变。
    expect(
      (payloads.last['light'] as Map)['stats'],
      (before.last['light'] as Map)['stats'],
    );
  });

  testWidgets('外观模式改成跟随系统时 sys 翻真', (tester) async {
    await pumpHost(tester);

    await pumpHost(tester, followsSystem: true);

    expect(themePayloads().last['sys'], isTrue);
  });

  testWidgets('非 Android 平台零调用', (tester) async {
    await pumpHost(tester, supported: false);

    expect(calls, isEmpty);
  });

  testWidgets('回前台但外观未变时不推', (tester) async {
    await pumpHost(tester);
    final before = themePayloads().length;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);

    expect(themePayloads(), hasLength(before));
  });
}
