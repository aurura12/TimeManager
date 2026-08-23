import 'dart:async';
import 'dart:convert';

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
  ) async =>
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
    ClientAuthorizationTokensForScopesParameters params,
  ) async =>
      null;

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async =>
      null;

  @override
  Future<void> clearAuthorizationToken(
    ClearAuthorizationTokenParams params,
  ) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

Future<TimeProvider> _createProvider({
  Duration? scheduleGiteeDebounce,
  Map<String, Object> initialPreferences = const {},
}) async {
  SharedPreferences.setMockInitialValues(initialPreferences);
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

  test('undo restores the last edited non-current desktop date', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);

    final targetDate = provider.currentDate.subtract(const Duration(days: 1));
    provider.assignCategoryToSlots(
      {0},
      Category(name: '测试', color: Colors.blue),
      date: targetDate,
    );
    expect(provider.slotsForDate(targetDate)[0].recorded, isTrue);

    provider.undo();

    expect(provider.slotsForDate(targetDate)[0].recorded, isFalse);
  });

  test('category reorder accepts the final destination index', () async {
    final provider = await _createProvider();
    addTearDown(provider.dispose);
    final originalNames =
        provider.categories.map((category) => category.name).toList();

    provider.reorderCategories(0, 2);

    expect(
      provider.categories.map((category) => category.name),
      [
        originalNames[1],
        originalNames[2],
        originalNames[0],
        ...originalNames.skip(3)
      ],
    );
  });

  test('edits to multiple desktop dates all trigger schedule sync attempts',
      () async {
    final provider = await _createProvider(
      scheduleGiteeDebounce: Duration.zero,
    );
    addTearDown(provider.dispose);
    final messages = <String>[];
    final subscription = provider.scheduleGiteeSyncStream.listen(messages.add);
    addTearDown(subscription.cancel);

    final previousDate = provider.currentDate.subtract(const Duration(days: 1));
    final nextDate = provider.currentDate.add(const Duration(days: 1));
    final category = Category(name: '测试', color: Colors.blue);
    provider.assignCategoryToSlots({0}, category, date: previousDate);
    provider.assignCategoryToSlots({1}, category, date: nextDate);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(messages.where((message) => message == '请先选择身份').length, 2);
  });

  test('deleting a slot writes a tombstone so it cannot resurrect', () async {
    final provider = await _createProvider(
      scheduleGiteeDebounce: Duration.zero,
    );
    addTearDown(provider.dispose);
    final date = provider.currentDate;
    final category = Category(name: '测试', color: Colors.blue);

    provider.assignCategoryToSlots({3}, category);
    expect(provider.slotsForDate(date)[3].recorded, isTrue);
    expect(provider.slotsForDate(date)[3].deletedAt, isNull);

    provider.removeEventFromSlot(3);
    expect(provider.slotsForDate(date)[3].recorded, isFalse);
    expect(provider.slotsForDate(date)[3].deletedAt, isNotNull);

    // 重新记录会清除墓碑
    provider.assignCategoryToSlots({3}, category);
    expect(provider.slotsForDate(date)[3].recorded, isTrue);
    expect(provider.slotsForDate(date)[3].deletedAt, isNull);
  });

  test('deleting a Google import writes a calendar-scoped tombstone', () async {
    final now = DateTime.now();
    final dateKey =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final provider = await _createProvider(
      initialPreferences: {
        'daily_slots': json.encode({
          dateKey: [
            {
              'i': 6,
              'l': '外部会议',
              'fc': true,
              'eid': 'google-event-1',
              'ts': 1787443200123,
            },
          ],
        }),
      },
    );
    addTearDown(provider.dispose);

    final deletionCompleted = Completer<void>();
    void deletionListener() {
      if (!deletionCompleted.isCompleted &&
          provider.slotsForDate(now)[6].deletedAt != null) {
        deletionCompleted.complete();
      }
    }

    provider.addListener(deletionListener);
    addTearDown(() => provider.removeListener(deletionListener));

    provider.removeEventFromSlot(6);

    final deletedSlot = provider.slotsForDate(now)[6];
    expect(deletedSlot.recorded, isFalse);
    expect(deletedSlot.deletedAt, isNotNull);
    expect(deletedSlot.isFromCalendar, isTrue);

    final dailySlots = provider.toBackupMap()['dailySlots'] as Map;
    final serializedSlots = dailySlots[dateKey] as List;
    final tombstone = serializedSlots.single as Map;
    expect(tombstone['del'], true);
    expect(tombstone['fc'], true);

    await deletionCompleted.future.timeout(const Duration(seconds: 5));
  });

  test('loading persisted slots restores modifiedAt for the next sync',
      () async {
    const dateKey = '2026-08-23';
    const modifiedAtMs = 1787443200123;
    final provider = await _createProvider(
      initialPreferences: {
        'daily_slots': json.encode({
          dateKey: [
            {
              'i': 3,
              'l': '测试',
              'c': 4280391411,
              'ts': modifiedAtMs,
            },
          ],
        }),
      },
    );
    addTearDown(provider.dispose);

    final loadedSlot = provider.getSlotsForDate(dateKey)![3];
    expect(loadedSlot.modifiedAt?.millisecondsSinceEpoch, modifiedAtMs);

    final dailySlots = provider.toBackupMap()['dailySlots'] as Map;
    final serializedSlots = dailySlots[dateKey] as List;
    final serializedSlot = serializedSlots.single as Map;
    expect(serializedSlot['ts'], modifiedAtMs);
  });

  test('loading a calendar-scoped tombstone restores its origin', () async {
    const dateKey = '2026-08-23';
    const deletedAtMs = 1787443200123;
    final provider = await _createProvider(
      initialPreferences: {
        'daily_slots': json.encode({
          dateKey: [
            {
              'i': 7,
              'del': true,
              'fc': true,
              'ts': deletedAtMs,
            },
          ],
        }),
      },
    );
    addTearDown(provider.dispose);

    final tombstone = provider.getSlotsForDate(dateKey)![7];
    expect(tombstone.recorded, isFalse);
    expect(tombstone.deletedAt?.millisecondsSinceEpoch, deletedAtMs);
    expect(tombstone.isFromCalendar, isTrue);
  });

  test('loading legacy slots without ts keeps modifiedAt unset', () async {
    const dateKey = '2026-08-22';
    final provider = await _createProvider(
      initialPreferences: {
        'daily_slots': json.encode({
          dateKey: [
            {
              'i': 4,
              'l': '旧数据',
              'c': 4283215696,
            },
          ],
        }),
      },
    );
    addTearDown(provider.dispose);

    expect(provider.getSlotsForDate(dateKey)![4].modifiedAt, isNull);
  });
}
