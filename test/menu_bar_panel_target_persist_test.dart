import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/menu_bar_target_store.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/menu_bar_panel.dart';
import 'package:time_manager/widgets/menu_bar_target_dial.dart';

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

Widget _panel(TimeProvider provider) {
  return ChangeNotifierProvider<TimeProvider?>.value(
    value: provider,
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(
        body: Center(
          child: SizedBox(width: 400, height: 720, child: MenuBarPanel()),
        ),
      ),
    ),
  );
}

FixedExtentScrollController _categoryController(WidgetTester tester) {
  final wheel = tester.widget<ListWheelScrollView>(
    find.byKey(MenuBarTargetDial.categoryWheelKey),
  );
  return wheel.controller! as FixedExtentScrollController;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('写入后记住目标，下次打开转盘停在同一分类', (tester) async {
    final provider = await _createProvider(tester);
    provider.addCategory(
      Category(id: 'c1', name: '工作', color: Colors.blue),
    );
    provider.addCategory(
      Category(id: 'c2', name: '休息', color: Colors.green),
    );

    await tester.pumpWidget(_panel(provider));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('menu-bar-time-grid')),
      const Offset(0, 40),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.byType(MenuBarTargetDial), findsOneWidget);
    // 分类顺序：[临时, 工作, 休息]；拨到「休息」，停下自动写入。
    _categoryController(tester).jumpToItem(2);
    await tester.pump();
    await tester.pump(
      MenuBarTargetDial.settleDelay + const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(MenuBarTargetStore.storageKey);
    expect(raw, isNotNull);
    expect(raw, contains('"categoryId":"c2"'));

    // 重新挂载一个面板：读回目标后，转盘应停在「休息」。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_panel(provider));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('menu-bar-time-grid')),
      const Offset(0, 40),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(_categoryController(tester).initialItem, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
    await tester.pump();
  });
}