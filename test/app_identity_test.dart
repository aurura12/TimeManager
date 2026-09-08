import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/google_calendar_user.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/daily_review_chat_store.dart';
import 'package:time_manager/services/daily_review_summary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  test('manual identity is deterministic and does not depend on Google', () {
    final identity = AppIdentityResolver.resolve(
      mode: AppIdentityMode.manual,
      manualKind: DiaryKind.j,
      googleUser: const GoogleCalendarUser(
        email: 'zjq031115a@gmail.com',
        id: 'google-g',
      ),
    );

    expect(identity, isNotNull);
    expect(identity!.person, DiaryKind.j);
    expect(identity.stableId, 'manual-j');
    expect(identity.email, '1746528702@qq.com');
  });

  test('known Google identity maps to the matching logical person', () {
    final identity = AppIdentityResolver.resolve(
      mode: AppIdentityMode.google,
      googleUser: const GoogleCalendarUser(
        email: 'ZJQ031115A@GMAIL.COM',
        id: 'google-g',
      ),
    );

    expect(identity, isNotNull);
    expect(identity!.person, DiaryKind.g);
    expect(identity.stableId, 'google-google-g');
  });

  test('unknown Google identity remains unbound', () {
    final identity = AppIdentityResolver.resolve(
      mode: AppIdentityMode.google,
      googleUser: const GoogleCalendarUser(
        email: 'someone@example.com',
        id: 'unknown',
      ),
    );

    expect(identity, isNull);
  });

  test('identity mode decoding defaults to manual only when unspecified', () {
    expect(AppIdentityModeX.fromCode(null), AppIdentityMode.manual);
    expect(AppIdentityModeX.fromCode('manual'), AppIdentityMode.manual);
    expect(AppIdentityModeX.fromCode('google'), AppIdentityMode.google);
    expect(AppIdentityModeX.fromCode('unexpected'), AppIdentityMode.manual);
  });

  test('logical person data keys are stable and isolated', () {
    expect(
      AppIdentityResolver.dataKey(DiaryKind.g, 'daily_slots'),
      'identity_g_daily_slots',
    );
    expect(
      AppIdentityResolver.dataKey(DiaryKind.j, 'daily_slots'),
      'identity_j_daily_slots',
    );
  });

  test('persisted manual mode restores the selected logical person', () async {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
    });

    await AppIdentityService.load();

    expect(AppIdentityService.mode, AppIdentityMode.manual);
    expect(AppIdentityService.personKind, DiaryKind.j);
    expect(AppIdentityService.currentUser?.id, 'manual-j');
  });

  test('persisted Google mode stays unbound until a known account is present',
      () async {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'google',
      AppIdentityService.legacySyncKey: true,
    });

    await AppIdentityService.load();

    expect(AppIdentityService.mode, AppIdentityMode.google);
    expect(AppIdentityService.personKind, isNull);
    expect(AppIdentityService.currentUser, isNull);
  });

  test('legacy sync flag only selects Google mode when explicit mode is absent',
      () async {
    SharedPreferences.setMockInitialValues({
      AppIdentityService.legacySyncKey: true,
    });

    await AppIdentityService.load();

    expect(AppIdentityService.mode, AppIdentityMode.google);
  });

  test('daily review reads only the selected identity namespace', () async {
    const date = '2026-09-08';
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
      'daily_slots': json.encode({
        date: [
          {'i': 0, 'l': '不应读取的旧数据', 'c': 1, 'ts': 1},
        ],
      }),
      'identity_j_daily_slots': json.encode({
        date: [
          {'i': 0, 'l': '晶晶的记录', 'c': 1, 'ts': 1},
        ],
      }),
    });

    final context = await DailyReviewSummaryBuilder.buildDayContext(
      DateTime(2026, 9, 8),
    );

    expect(context, contains('晶晶的记录'));
    expect(context, isNot(contains('不应读取的旧数据')));
  });

  test('daily review chat uses only the selected identity namespace', () async {
    const date = '2026-09-08';
    SharedPreferences.setMockInitialValues({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
      'daily_review_chat_$date': json.encode([
        {
          'role': 'user',
          'content': '不应读取的旧对话',
          'createdAt': 1,
        },
      ]),
      'identity_j_daily_review_chat_$date': json.encode([
        {
          'role': 'user',
          'content': '晶晶的对话',
          'createdAt': 1,
        },
      ]),
    });

    final session = await DailyReviewChatStore.loadSession(
      DateTime(2026, 9, 8),
    );

    expect(session.messages.single.content, '晶晶的对话');
  });
}
