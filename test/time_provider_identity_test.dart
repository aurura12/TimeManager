import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';

ScheduleSyncDependencies _offlineDependencies() {
  return ScheduleSyncDependencies(
    loadToken: () async => null,
    listPaths: ({required token, required userCode}) async {
      return ScheduleGiteeListWithShaResult.error('offline');
    },
    pullDay: ({required token, required dateKey, required userCode}) async {
      return ScheduleGiteePullResult.error('offline');
    },
  );
}

Future<TimeProvider> _createMobileIdentityProvider(
  Map<String, Object> preferences,
) async {
  SharedPreferences.setMockInitialValues(preferences);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  final provider = TimeProvider(
    identityModePlatformOverride: true,
    scheduleSyncDependencies: _offlineDependencies(),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppIdentityService.resetForTesting();
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  test('mobile provider loads schedule data from the selected namespace',
      () async {
    final provider = await _createMobileIdentityProvider({
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: 'j',
      'identity_j_daily_slots': json.encode({
        '2026-09-08': [
          {'i': 0, 'l': '晶晶专属日程', 'c': 1, 'ts': 1},
        ],
      }),
      'daily_slots': json.encode({
        '2026-09-08': [
          {'i': 0, 'l': '不应读取的全局日程', 'c': 1, 'ts': 1},
        ],
      }),
    });
    addTearDown(provider.dispose);

    expect(provider.identityMode, AppIdentityMode.manual);
    expect(provider.scheduleUser, DiaryKind.j);
    expect(provider.hasSelectedScheduleUser, isTrue);
    expect(
      provider.getSlotsForDate('2026-09-08')?.first.label,
      '晶晶专属日程',
    );
  });

  test('mobile provider keeps global legacy data unread before identity choice',
      () async {
    final provider = await _createMobileIdentityProvider({
      'daily_slots': json.encode({
        '2026-09-08': [
          {'i': 0, 'l': '不应读取的全局日程', 'c': 1, 'ts': 1},
        ],
      }),
    });
    addTearDown(provider.dispose);

    expect(provider.hasSelectedScheduleUser, isFalse);
    expect(provider.getSlotsForDate('2026-09-08'), isNull);
  });
}
