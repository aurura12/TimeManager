import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/menu_bar_event_editor.dart';

class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
          AttemptLightweightAuthenticationParameters params) async =>
      null;

  @override
  bool supportsAuthenticate() => false;

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) {
    throw UnimplementedError();
  }

  @override
  bool authorizationRequiresUserInteraction() => false;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
          ClientAuthorizationTokensForScopesParameters params) async =>
      null;

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
          ServerAuthorizationTokensForScopesParameters params) async =>
      null;

  @override
  Future<void> clearAuthorizationToken(
      ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

Future<TimeProvider> _createProvider(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();
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

  final provider = await tester.runAsync(() async {
    final created = TimeProvider();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!created.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return created;
  });
  return provider!;
}

Future<void> _openEditor(
  WidgetTester tester,
  TimeProvider provider,
  DateTime date,
  DateTime now,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMenuBarEventEditor(
              context,
              provider: provider,
              date: date,
              now: now,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

/// 关掉弹层、停掉 TimeProvider 的防抖定时器，避免测试结束时留下 pending timer。
Future<void> _teardown(
  WidgetTester tester,
  TimeProvider provider,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  provider.dispose();
  await tester.pump();
}


/// 分类 chip 在横向列表里，可能有一部分在可视区外；先滚到可见再点，
/// 避免 hit test 落空（否则会刷一条 warnIfMissed 警告）。
Future<void> _tapVisible(WidgetTester tester, String text) async {
  // 直接点 chip 本身，避免点到字形的命中区（部分 chip 的文字不在命中路径里，
  // 会刷 warnIfMissed 警告）。
  var chip = find.widgetWithText(ChoiceChip, text);
  if (chip.evaluate().isEmpty) {
    chip = find.widgetWithText(ActionChip, text);
  }
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('默认取整到 10 分钟并保存到指定日期', (tester) async {
    final provider = await _createProvider(tester);
    provider.addCategory(
      Category(id: 'work', name: '工作', color: Colors.blue, subCategories: ['开会']),
    );
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);

    await _openEditor(
      tester,
      provider,
      day,
      DateTime(day.year, day.month, day.day, 9, 3),
    );

    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);

    await _tapVisible(tester, '工作');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final recorded = provider
        .slotsForDate(day)
        .where((slot) => slot.recorded)
        .toList(growable: false);
    expect(recorded, hasLength(6));
    expect(recorded.first.label, '工作');
    expect(find.text('已添加 09:00-10:00 工作'), findsOneWidget);

    await _teardown(tester, provider);
  });

  testWidgets('点分类下的子事件会填入事件名', (tester) async {
    final provider = await _createProvider(tester);
    provider.addCategory(
      Category(id: 'work', name: '工作', color: Colors.blue, subCategories: ['开会']),
    );
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);

    await _openEditor(
      tester,
      provider,
      day,
      DateTime(day.year, day.month, day.day, 9, 3),
    );

    await _tapVisible(tester, '工作');
    await _tapVisible(tester, '开会');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final recorded = provider
        .slotsForDate(day)
        .where((slot) => slot.recorded)
        .toList(growable: false);
    expect(recorded.first.label, '开会');

    await _teardown(tester, provider);
  });

  testWidgets('保存后可以撤销', (tester) async {
    final provider = await _createProvider(tester);
    provider.addCategory(
      Category(id: 'work', name: '工作', color: Colors.blue),
    );
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);

    await _openEditor(
      tester,
      provider,
      day,
      DateTime(day.year, day.month, day.day, 9, 3),
    );

    await _tapVisible(tester, '工作');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      provider.slotsForDate(day).where((slot) => slot.recorded),
      isNotEmpty,
    );

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(
      provider.slotsForDate(day).where((slot) => slot.recorded),
      isEmpty,
    );

    await _teardown(tester, provider);
  });
}