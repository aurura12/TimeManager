import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/menu_bar_panel.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('拖选后点分类会写入当天记录', (tester) async {
    final provider = await _createProvider(tester);
    provider.addCategory(
      Category(id: 'work', name: '工作', color: Colors.blue),
    );
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);

    await tester.pumpWidget(
      ChangeNotifierProvider<TimeProvider?>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 680, child: MenuBarPanel()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 先在格子上拖选一段时间，再点分类写入（与记录页一致）。
    await tester.drag(
      find.byKey(const ValueKey('menu-bar-time-grid')),
      const Offset(0, 40),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, '工作'));
    await tester.pumpAndSettle();

    final recorded = provider
        .slotsForDate(day)
        .where((slot) => slot.recorded)
        .toList(growable: false);
    expect(recorded, isNotEmpty);
    expect(recorded.first.label, '工作');

    // 卸载树并停掉 Provider 的防抖定时器，避免测试结束时残留 timer。
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
    await tester.pump();
  });
}