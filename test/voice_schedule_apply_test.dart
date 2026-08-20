import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/voice_schedule_draft.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/widgets/voice_schedule_sheet.dart';

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

Future<TimeProvider> _createProvider() async {
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

  final provider = TimeProvider();
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('应用语音草稿时写入已有事件的分类 ID', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);
    provider.addCategory(Category(
      id: 'work',
      name: '工作',
      color: Colors.blue,
      subCategories: ['开会'],
    ));

    final result = provider.applyVoiceSchedule(
      VoiceScheduleDraft(
        date: provider.currentDate,
        startIndex: 90,
        endIndexExclusive: 96,
        label: '开会',
        categoryId: 'work',
        transcript: '下午三点到四点开会',
        eventKind: VoiceScheduleEventKind.existing,
      ),
    );

    expect(result.appliedSlotCount, 6);
    expect(provider.slots[90].label, '开会');
    expect(provider.slots[90].categoryId, 'work');
  });

  test('应用语音草稿时未匹配事件会写入临时标签但不新增分类', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);

    final result = provider.applyVoiceSchedule(
      VoiceScheduleDraft(
        date: provider.currentDate,
        startIndex: 90,
        endIndexExclusive: 96,
        label: '去健身房',
        categoryId: null,
        transcript: '下午三点到四点去健身房',
        eventKind: VoiceScheduleEventKind.temporary,
      ),
    );

    expect(result.appliedSlotCount, 6);
    expect(provider.slots[90].label, '去健身房');
    expect(provider.slots[90].categoryId, isNotNull);
    expect(provider.categories.any((c) => c.name == '去健身房'), isFalse);
  });

  testWidgets('语音添加弹窗聚焦文字框并提示使用系统键盘麦克风', (tester) async {
    await tester.runAsync(() async {
      final provider = await _createProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceScheduleSheet(
              provider: provider,
              baseDate: provider.currentDate,
            ),
          ),
        ),
      );
      await tester.pump();

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.autofocus, isTrue);
      expect(find.textContaining('系统键盘上的麦克风'), findsOneWidget);
    });
  });
}
