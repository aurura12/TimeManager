import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/utils/schedule_view_dates.dart';

class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async => null;

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
    ClientAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<void> clearAuthorizationToken(
    ClearAuthorizationTokenParams params,
  ) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

Future<TimeProvider> _createProvider({Duration? scheduleGiteeDebounce}) async {
  SharedPreferences.setMockInitialValues({});
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

  final provider = scheduleGiteeDebounce == null
      ? TimeProvider()
      : TimeProvider(scheduleGiteeDebounce: scheduleGiteeDebounce);
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop schedule view refreshes previous, current, and next dates', () {
    final dates = scheduleDatesForView(
      DateTime(2026, 8, 19, 15),
      desktop: true,
    );
    expect(dates, [
      DateTime(2026, 8, 18),
      DateTime(2026, 8, 19),
      DateTime(2026, 8, 20),
    ]);
  });

  test('editing an explicitly selected non-current date schedules Gitee sync',
      () async {
    final provider = await _createProvider(
      scheduleGiteeDebounce: Duration.zero,
    );
    addTearDown(provider.dispose);
    final messages = <String>[];
    final subscription = provider.scheduleGiteeSyncStream.listen(messages.add);
    addTearDown(subscription.cancel);

    final targetDate = provider.currentDate.subtract(const Duration(days: 1));
    provider.assignCategoryToSlots(
      {0},
      Category(name: '测试', color: Colors.blue),
      date: targetDate,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(messages, contains('请先选择身份'));
  });
}
