import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_overwrite.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';

const _localPreferences = <String, Object>{
  'daily_slots':
      '{"2026-01-01":[{"i":0,"l":"本地专属","c":2,"cid":"local-category","ts":1000}],"2026-09-06":[{"i":0,"l":"本地重叠","c":3,"cid":"local-category","ts":1000}]}',
  'pending_gitee_sync_dates': <String>['2026-01-01', '2026-09-06'],
  'pending_google_sync_dates': <String>['2026-09-06', '2026-10-01'],
};

const _remoteCanonicalContent =
    '{"updated_at":2000,"slots":[{"i":0,"l":"远端","c":1,"cid":"g-category","ts":2000}]}';

ScheduleSyncDependencies _fakeDependencies({required bool failPull}) {
  return ScheduleSyncDependencies(
    loadToken: () async => 'fake-token',
    listPaths: ({required token, required userCode}) async {
      if (token != 'fake-token' || userCode != 'g') {
        return ScheduleGiteeListWithShaResult.error('参数错误');
      }
      return ScheduleGiteeListWithShaResult.success({
        'schedule/g/2026-09-06.json': 'remote-sha',
      });
    },
    pullDay: ({required token, required dateKey, required userCode}) async {
      if (token != 'fake-token' || dateKey != '2026-09-06' || userCode != 'g') {
        return ScheduleGiteePullResult.error('参数错误');
      }
      if (failPull) return ScheduleGiteePullResult.error('读取失败');
      return ScheduleGiteePullResult.success(
        _remoteCanonicalContent,
        'remote-sha',
      );
    },
  );
}

Future<TimeProvider> _createProvider({required bool failPull}) async {
  SharedPreferences.setMockInitialValues(_localPreferences);
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

  final provider = TimeProvider(
    scheduleSyncDependencies: _fakeDependencies(failPull: failPull),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await provider.setScheduleUser(DiaryKind.g);
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts only padded canonical paths for the selected user', () {
    expect(
      ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
        'schedule/g/2026-09-06.json',
        userCode: 'g',
      ),
      isTrue,
    );
    expect(
      ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
        'schedule/g/2026-9-6.json',
        userCode: 'g',
      ),
      isFalse,
    );
    expect(
      ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
        'schedule/j/2026-09-06.json',
        userCode: 'g',
      ),
      isFalse,
    );
    expect(
      ScheduleOverwriteSnapshot.dateKeyFromCanonicalPath(
        'schedule/g/2026-09-06.json',
        userCode: 'g',
      ),
      '2026-09-06',
    );
    expect(
      ScheduleOverwriteSnapshot.isCanonicalSchedulePath(
        'schedule/x/2026-09-06.json',
        userCode: 'x',
      ),
      isFalse,
    );
  });

  test('parses object and legacy array forms and ignores unpadded paths', () {
    final result = ScheduleOverwriteSnapshot.fromRemoteFiles(
      userCode: 'g',
      contentsByPath: {
        'schedule/g/2026-09-06.json': jsonEncode({
          'updated_at': 10,
          'slots': [
            {'i': 2, 'l': '对象'},
          ],
        }),
        'schedule/g/2026-9-7.json': '[{"i": 1, "l": "忽略"}]',
        'schedule/g/2026-09-08.json': '[{"i": 4, "l": "旧数组"}]',
      },
    );

    expect(result.isValid, isTrue);
    expect(result.entriesByDate, {
      '2026-09-06': [
        {'i': 2, 'l': '对象'},
      ],
      '2026-09-08': [
        {'i': 4, 'l': '旧数组'},
      ],
    });
  });

  test('fromRemoteFiles returns only entries in the selected user namespace',
      () {
    final result = ScheduleOverwriteSnapshot.fromRemoteFiles(
      userCode: 'g',
      contentsByPath: {
        'schedule/g/2026-09-06.json': '[{"i": 1, "l": "乖乖"}]',
        'schedule/j/2026-09-06.json': '[{"i": 2, "l": "晶晶"}]',
      },
    );

    expect(result.isValid, isTrue);
    expect(result.entriesByDate, {
      '2026-09-06': [
        {'i': 1, 'l': '乖乖'},
      ],
    });
  });

  final invalidCases = <String, String>{
    'malformed JSON': '{',
    'non-list slots': '{"updated_at": 1, "slots": {}}',
    'non-map slot': '{"slots": [1]}',
    'non-integer index': '{"slots": [{"i": 1.5, "l": "x"}]}',
    'out-of-range index': '{"slots": [{"i": 144, "l": "x"}]}',
    'duplicate index': '{"slots": [{"i": 1, "l": "a"}, {"i": 1, "l": "b"}]}',
    'empty required field': '{"slots": [{"i": 1, "l": ""}]}',
    'missing required field': '{"slots": [{"i": 1}]}',
    'wrongly typed required field': '{"slots": [{"i": 1, "l": 123}]}',
    'wrongly typed force-color field':
        '{"slots": [{"i": 1, "l": "x", "fc": "false"}]}',
  };

  for (final entry in invalidCases.entries) {
    test('invalidates the entire snapshot for ${entry.key}', () {
      final result = ScheduleOverwriteSnapshot.fromRemoteFiles(
        userCode: 'g',
        contentsByPath: {
          'schedule/g/2026-09-06.json': entry.value,
          'schedule/g/2026-09-07.json': '[{"i": 2, "l": "must not apply"}]',
        },
      );

      expect(result.isValid, isFalse);
      expect(result.entriesByDate, isEmpty);
      expect(result.error, isNotNull);
    });
  }

  test('sorts valid entries by index and retains a legal tombstone', () {
    final result = ScheduleOverwriteSnapshot.fromRemoteFiles(
      userCode: 'g',
      contentsByPath: {
        'schedule/g/2026-09-06.json': jsonEncode({
          'slots': [
            {'i': 10, 'l': '晚', 'ts': 3},
            {'i': 3, 'del': true, 'ts': 4},
            {'i': 1, 'l': '早', 'cid': 'c'},
          ],
        }),
      },
    );

    expect(result.isValid, isTrue);
    expect(result.entriesByDate['2026-09-06']!.map((e) => e['i']), [1, 3, 10]);
    expect(result.entriesByDate['2026-09-06']![1], {
      'i': 3,
      'del': true,
      'ts': 4,
    });
  });

  test('overwrite replaces local days and clears both pending sync sets',
      () async {
    final provider = await _createProvider(failPull: false);
    addTearDown(provider.dispose);

    final overwritten = await provider.overwriteAllSchedulesFromGitee();

    expect(overwritten, isTrue);
    expect(provider.getSlotsForDate('2026-01-01'), isNull);
    final replaced = provider.getSlotsForDate('2026-09-06');
    expect(replaced, isNotNull);
    expect(replaced![0].label, '远端');
    expect(replaced[0].color?.toARGB32(), 1);
    expect(provider.pendingGiteeSyncDates, isEmpty);
    expect(provider.pendingGoogleSyncDates, isEmpty);
  });

  test('overwrite pull failure preserves all local and pending state',
      () async {
    final provider = await _createProvider(failPull: true);
    addTearDown(provider.dispose);

    final overwritten = await provider.overwriteAllSchedulesFromGitee();

    expect(overwritten, isFalse);
    expect(provider.getSlotsForDate('2026-01-01')![0].label, '本地专属');
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '本地重叠');
    expect(
      provider.pendingGiteeSyncDates,
      {'2026-01-01', '2026-09-06'},
    );
    expect(
      provider.pendingGoogleSyncDates,
      {'2026-09-06', '2026-10-01'},
    );
  });
}
