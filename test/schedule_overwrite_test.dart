import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_overwrite.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/widgets/profile_settings_drawer.dart';
import 'package:provider/provider.dart';

const _localPreferences = <String, Object>{
  'daily_slots':
      '{"2026-01-01":[{"i":0,"l":"本地专属","c":2,"cid":"local-category","ts":1000}],"2026-09-06":[{"i":0,"l":"本地重叠","c":3,"cid":"local-category","ts":1000}]}',
  'pending_gitee_sync_dates': <String>['2026-01-01', '2026-09-06'],
  'pending_google_sync_dates': <String>['2026-09-06', '2026-10-01'],
  'pending_sync_dates': <String>[
    '2026-01-01',
    '2026-09-06',
    '2026-10-01',
  ],
};

const _remoteCanonicalContent =
    '{"updated_at":2000,"slots":[{"i":0,"l":"远端","c":1,"cid":"g-category","ts":2000}]}';

ScheduleSyncDependencies _fakeDependencies({
  required bool failPull,
  Completer<void>? pullGate,
  int gateOnPullNumber = 1,
  String? gateDateKey,
  bool Function()? shouldGate,
  Completer<void>? googlePullGate,
  void Function()? onListPaths,
  void Function()? onPullDay,
  void Function()? onGooglePull,
  void Function()? onGiteeUpload,
  void Function()? onGoogleUpload,
  String? pullSha,
  Map<String, String>? pathShaMap,
}) {
  var pullCount = 0;
  return ScheduleSyncDependencies(
    loadToken: () async => 'fake-token',
    listPaths: ({required token, required userCode}) async {
      onListPaths?.call();
      if (token != 'fake-token' || userCode != 'g') {
        return ScheduleGiteeListWithShaResult.error('参数错误');
      }
      return ScheduleGiteeListWithShaResult.success(
        pathShaMap ?? {'schedule/g/2026-09-06.json': 'remote-sha'},
      );
    },
    pullDay: ({required token, required dateKey, required userCode}) async {
      onPullDay?.call();
      pullCount++;
      if (pullGate != null &&
          pullCount >= gateOnPullNumber &&
          (gateDateKey == null || dateKey == gateDateKey) &&
          (shouldGate?.call() ?? true)) {
        await pullGate.future;
      }
      if (token != 'fake-token' || dateKey != '2026-09-06' || userCode != 'g') {
        return ScheduleGiteePullResult.error('参数错误');
      }
      if (failPull) return ScheduleGiteePullResult.error('读取失败');
      return ScheduleGiteePullResult.success(
        _remoteCanonicalContent,
        pullSha ?? 'remote-sha',
      );
    },
    pushDay: ({
      required token,
      required dateKey,
      required userCode,
      required content,
      required commitMessage,
    }) async {
      onGiteeUpload?.call();
      return ScheduleGiteePushResult.success(created: false);
    },
    pushGoogleDay: (slots, date) async {
      onGoogleUpload?.call();
      return true;
    },
    pullGoogleDay: (date) async {
      onGooglePull?.call();
      if (googlePullGate != null) await googlePullGate.future;
      return const [];
    },
  );
}

Future<TimeProvider> _createProvider({
  required bool failPull,
  Map<String, Object> initialPreferences = _localPreferences,
  ScheduleSyncDependencies? dependencies,
  Future<bool> Function()? saveDataOverride,
  void Function(String key)? scheduleSnapshotWriteObserver,
  void Function(String phase)? scheduleSnapshotJournalPhaseObserver,
  Future<bool> Function()? scheduleSnapshotJournalRemoveOverride,
  Duration scheduleGiteeDebounce = const Duration(seconds: 3),
  Duration googleCalendarDebounce = const Duration(seconds: 3),
  bool? googleCalendarSyncPlatformOverride,
  bool? googleCalendarSignedInOverride,
}) async {
  SharedPreferences.setMockInitialValues(initialPreferences);
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
    scheduleGiteeDebounce: scheduleGiteeDebounce,
    googleCalendarDebounce: googleCalendarDebounce,
    googleCalendarSyncPlatformOverride: googleCalendarSyncPlatformOverride,
    googleCalendarSignedInOverride: googleCalendarSignedInOverride,
    scheduleSyncDependencies:
        dependencies ?? _fakeDependencies(failPull: failPull),
    saveDataOverride: saveDataOverride,
    scheduleSnapshotWriteObserver: scheduleSnapshotWriteObserver,
    scheduleSnapshotJournalPhaseObserver: scheduleSnapshotJournalPhaseObserver,
    scheduleSnapshotJournalRemoveOverride:
        scheduleSnapshotJournalRemoveOverride,
  );
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await provider.setScheduleUser(DiaryKind.g);
  await Future<void>.delayed(const Duration(milliseconds: 200));
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
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: _localPreferences,
    );
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
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('daily_slots'), isNotNull);
    expect(prefs.getStringList('pending_gitee_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_google_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_sync_dates'), isEmpty);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
  });

  test('overwrite with an empty canonical remote clears every local day',
      () async {
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: _localPreferences,
      dependencies: _fakeDependencies(
        failPull: false,
        pathShaMap: const {},
      ),
    );
    addTearDown(provider.dispose);

    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);
    expect(provider.getSlotsForDate('2026-01-01'), isNull);
    expect(provider.getSlotsForDate('2026-09-06'), isNull);
    expect(provider.pendingGiteeSyncDates, isEmpty);
    expect(provider.pendingGoogleSyncDates, isEmpty);
  });

  test('successful overwrite clears every pending queue without uploading',
      () async {
    var giteeUploads = 0;
    var googleUploads = 0;
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
      scheduleGiteeDebounce: const Duration(milliseconds: 50),
      dependencies: _fakeDependencies(
        failPull: false,
        onGiteeUpload: () => giteeUploads++,
        onGoogleUpload: () => googleUploads++,
      ),
    );
    addTearDown(provider.dispose);

    final backup = provider.toBackupMap();
    backup['dailySlots'] =
        jsonDecode(_localPreferences['daily_slots']! as String);
    backup['pendingGiteeSyncDates'] = [
      '2026-01-01',
      '2026-09-06',
    ];
    backup['pendingGoogleSyncDates'] = [
      '2026-09-06',
      '2026-10-01',
    ];
    backup['pendingSyncDates'] = [
      '2026-01-01',
      '2026-09-06',
      '2026-10-01',
    ];
    await provider.importBackupJson(jsonEncode(backup));
    provider.assignCategoryToSlots(
      {1},
      Category(name: '覆盖前待同步', color: Colors.purple),
      date: DateTime(2026, 9, 6),
    );
    expect(provider.hasPendingScheduleGiteeUpload, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('daily_slots'), isNotNull);
    expect(prefs.getStringList('pending_gitee_sync_dates'), isNotEmpty);
    expect(prefs.getStringList('pending_google_sync_dates'), isNotEmpty);
    expect(prefs.getStringList('pending_sync_dates'), isNotEmpty);
    expect(giteeUploads, 0);
    expect(googleUploads, 0);

    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);
    expect(provider.pendingGiteeSyncDates, isEmpty);
    expect(provider.pendingGoogleSyncDates, isEmpty);
    expect(provider.hasPendingScheduleGiteeUpload, isFalse);
    expect(prefs.getStringList('pending_gitee_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_google_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_sync_dates'), isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(giteeUploads, 0);
    expect(googleUploads, 0);
  });

  test('startup restores an interrupted overwrite journal before loading slots',
      () async {
    const oldSlots =
        '{"2026-01-01":[{"i":0,"l":"恢复的本地日程","c":2,"cid":"local-category","ts":1000}]}';
    final journal = jsonEncode({
      'daily_slots': {'present': true, 'value': oldSlots},
      'pending_gitee_sync_dates': {
        'present': true,
        'value': ['2026-01-01'],
      },
      'pending_google_sync_dates': {
        'present': true,
        'value': ['2026-01-02'],
      },
      'pending_sync_dates': {
        'present': true,
        'value': ['2026-01-01', '2026-01-02'],
      },
    });
    SharedPreferences.setMockInitialValues({
      'daily_slots': '{"2026-09-06":[]}',
      'pending_gitee_sync_dates': <String>['2026-09-06'],
      'pending_google_sync_dates': <String>['2026-09-06'],
      'pending_sync_dates': <String>['2026-09-06'],
      'schedule_overwrite_transaction_journal': journal,
    });

    final provider = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(failPull: false),
    );
    addTearDown(provider.dispose);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        !provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(provider.getSlotsForDate('2026-01-01')![0].label, '恢复的本地日程');
    expect(provider.pendingGiteeSyncDates, {'2026-01-01'});
    expect(provider.pendingGoogleSyncDates, {'2026-01-02'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
    expect(prefs.getString('daily_slots'), oldSlots);
  });

  test('startup isolates a corrupt overwrite journal from background sync',
      () async {
    const oldSlots = '{"2026-01-01":[{"i":0,"l":"必须保留","c":2,"ts":1000}]}';
    const corruptJournal = '{"phase":"prepared","before":';
    var pullDayCalls = 0;
    SharedPreferences.setMockInitialValues({
      'daily_slots': oldSlots,
      'pending_gitee_sync_dates': <String>['2026-01-01'],
      'pending_google_sync_dates': <String>['2026-01-02'],
      'pending_sync_dates': <String>['2026-01-01', '2026-01-02'],
      'schedule_overwrite_transaction_journal': corruptJournal,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final arguments = call.arguments;
        if (call.method == 'read' &&
            arguments is Map &&
            arguments['key'] == 'app_user_identity_manual_kind') {
          return 'g';
        }
        return null;
      },
    );

    final provider = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(
        failPull: false,
        onPullDay: () => pullDayCalls++,
      ),
    );
    addTearDown(provider.dispose);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        !provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(provider.hasInitializationFailure, isTrue);
    expect(provider.initializationFailureMessage, contains('恢复'));
    expect(pullDayCalls, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('daily_slots'), oldSlots);
    expect(
      prefs.getString('schedule_overwrite_transaction_journal'),
      corruptJournal,
    );
  });

  test('initialization failure isolates every schedule sync and save entry',
      () async {
    const corruptJournal = '{"phase":"prepared","before":';
    var listCalls = 0;
    var pullCalls = 0;
    var giteeUploads = 0;
    var googleUploads = 0;
    SharedPreferences.setMockInitialValues({
      'daily_slots': _localPreferences['daily_slots']!,
      'pending_gitee_sync_dates':
          _localPreferences['pending_gitee_sync_dates']!,
      'pending_google_sync_dates':
          _localPreferences['pending_google_sync_dates']!,
      'pending_sync_dates': _localPreferences['pending_sync_dates']!,
      'schedule_overwrite_transaction_journal': corruptJournal,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );

    final provider = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(
        failPull: false,
        onListPaths: () => listCalls++,
        onPullDay: () => pullCalls++,
        onGiteeUpload: () => giteeUploads++,
        onGoogleUpload: () => googleUploads++,
      ),
    );
    addTearDown(provider.dispose);
    while (!provider.isInitialLoadFinished) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(provider.hasInitializationFailure, isTrue);
    final prefs = await SharedPreferences.getInstance();
    final beforeSlots = prefs.getString('daily_slots');
    final beforeGitee = prefs.getStringList('pending_gitee_sync_dates');
    final beforeGoogle = prefs.getStringList('pending_google_sync_dates');
    final beforeVisible = prefs.getStringList('pending_sync_dates');
    final beforeJournal =
        prefs.getString('schedule_overwrite_transaction_journal');
    final beforeRecorded = provider.slots[0].recorded;

    provider.toggleSlot(0);
    await provider.syncScheduleToGitee();
    await provider.syncAllSchedulesToGitee();
    await provider.pullScheduleFromGitee();
    await provider.pullAllSchedulesFromGitee();
    await provider.syncAll();
    await provider.synchronizeCalendar(delay: true);
    await provider.synchronizeAllPendingCalendars();
    await provider.pullGoogleCalendarForCurrentDate();
    await provider.pullGoogleCalendarForDate(DateTime(2026, 9, 6));
    await provider.onAppBackgrounded();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(provider.slots[0].recorded, beforeRecorded);
    expect(listCalls, 0);
    expect(pullCalls, 0);
    expect(giteeUploads, 0);
    expect(googleUploads, 0);
    expect(prefs.getString('daily_slots'), beforeSlots);
    expect(prefs.getStringList('pending_gitee_sync_dates'), beforeGitee);
    expect(prefs.getStringList('pending_google_sync_dates'), beforeGoogle);
    expect(prefs.getStringList('pending_sync_dates'), beforeVisible);
    expect(prefs.getString('schedule_overwrite_transaction_journal'),
        beforeJournal);
  });

  test('Gitee pull before initialization cannot commit remote memory',
      () async {
    const oldSlots = '{"2026-01-01":[{"i":0,"l":"必须保留","c":2,"ts":1000}]}';
    const corruptJournal = '{"phase":"prepared","before":';
    var pullCalls = 0;
    SharedPreferences.setMockInitialValues({
      'daily_slots': oldSlots,
      'schedule_overwrite_transaction_journal': corruptJournal,
    });

    final provider = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(
        failPull: false,
        onPullDay: () => pullCalls++,
      ),
    );
    addTearDown(provider.dispose);

    // Selecting the identity synchronously opens the public pull entry before
    // _init() reaches the corrupt journal failure.
    final selectUser = provider.setScheduleUser(DiaryKind.g);
    final pull = provider.pullScheduleFromGitee(
      date: DateTime(2026, 9, 6),
    );
    expect(await pull, isFalse);

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        !provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await selectUser;
    expect(provider.hasInitializationFailure, isTrue);
    expect(pullCalls, 0);
    expect(provider.getSlotsForDate('2026-09-06'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('daily_slots'), oldSlots);
    expect(
      prefs.getString('schedule_overwrite_transaction_journal'),
      corruptJournal,
    );
  });

  test('Gitee sync before initialization cannot upload or create slots',
      () async {
    const oldSlots = '{"2026-01-01":[{"i":0,"l":"必须保留","c":2,"ts":1000}]}';
    const corruptJournal = '{"phase":"prepared","before":';
    var giteeUploads = 0;
    SharedPreferences.setMockInitialValues({
      'daily_slots': oldSlots,
      'schedule_overwrite_transaction_journal': corruptJournal,
    });

    final provider = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(
        failPull: false,
        onGiteeUpload: () => giteeUploads++,
      ),
    );
    addTearDown(provider.dispose);

    final selectUser = provider.setScheduleUser(DiaryKind.g);
    final sync = provider.syncScheduleToGitee(
      dateKey: '2026-09-06',
    );
    await sync;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        !provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await selectUser;

    expect(giteeUploads, 0);
    expect(provider.getSlotsForDate('2026-09-06'), isNull);
    expect(provider.hasInitializationFailure, isTrue);
  });

  test(
      'Google pending sync before initialization cannot upload or create slots',
      () async {
    const corruptJournal = '{"phase":"prepared","before":';
    var googleUploads = 0;
    SharedPreferences.setMockInitialValues({
      'daily_slots': _localPreferences['daily_slots']!,
      'pending_google_sync_dates': <String>['2026-09-06'],
      'schedule_overwrite_transaction_journal': corruptJournal,
    });

    final provider = TimeProvider(
      googleCalendarSyncPlatformOverride: true,
      googleCalendarSignedInOverride: true,
      scheduleSyncDependencies: _fakeDependencies(
        failPull: false,
        onGoogleUpload: () => googleUploads++,
      ),
    );
    addTearDown(provider.dispose);

    final selectUser = provider.setScheduleUser(DiaryKind.g);
    final sync = provider.synchronizeAllPendingCalendars();
    await sync;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        !provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await selectUser;

    expect(googleUploads, 0);
    expect(provider.getSlotsForDate('2026-09-06'), isNull);
    expect(provider.hasInitializationFailure, isTrue);
  });

  test('overwrite pull failure preserves all local and pending state',
      () async {
    final provider = await _createProvider(
      failPull: true,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
    );
    addTearDown(provider.dispose);

    final seededBackup = Map<String, dynamic>.from(provider.toBackupMap());
    seededBackup['pendingGiteeSyncDates'] = [
      '2026-01-01',
      '2026-09-06',
    ];
    seededBackup['pendingGoogleSyncDates'] = [
      '2026-09-06',
      '2026-10-01',
    ];
    seededBackup['pendingSyncDates'] = [
      '2026-01-01',
      '2026-09-06',
      '2026-10-01',
    ];
    await provider.importBackupJson(jsonEncode(seededBackup));

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

  test('overwrite pull rejects concurrent reentry while the first pull runs',
      () async {
    final pullGate = Completer<void>();
    var gateEnabled = false;
    var listPathsCalls = 0;
    var pullDayCalls = 0;
    SharedPreferences.setMockInitialValues({
      'daily_slots': _localPreferences['daily_slots']!,
    });
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
      scheduleSyncDependencies: _fakeDependencies(
        failPull: false,
        pullGate: pullGate,
        gateDateKey: '2026-09-06',
        shouldGate: () => gateEnabled,
        onListPaths: () => listPathsCalls++,
        onPullDay: () => pullDayCalls++,
      ),
    );
    while (!provider.isInitialLoadFinished) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await provider.setScheduleUser(DiaryKind.g);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    addTearDown(provider.dispose);
    gateEnabled = true;

    final firstCall = provider.overwriteAllSchedulesFromGitee();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final secondCall = provider.overwriteAllSchedulesFromGitee();

    expect(await secondCall.timeout(const Duration(seconds: 1)), isFalse);
    expect(provider.lastScheduleOverwriteFailure, '覆盖拉取未开始：已有日程同步任务');
    expect(listPathsCalls, 1);
    expect(pullDayCalls, greaterThanOrEqualTo(1));

    pullGate.complete();
    expect(await firstCall, isTrue);
  });

  test('overwrite aborts when the selected identity changes during fetch',
      () async {
    final gate = Completer<void>();
    var gateEnabled = false;
    final provider = await _createProvider(
      failPull: false,
      dependencies: _fakeDependencies(
        failPull: false,
        pullGate: gate,
        gateDateKey: '2026-09-06',
        shouldGate: () => gateEnabled,
      ),
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
    );
    addTearDown(provider.dispose);
    gateEnabled = true;

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await provider.setScheduleUser(DiaryKind.j);
    gate.complete();

    expect(await overwrite, isFalse);
    expect(provider.scheduleUser, DiaryKind.j);
    expect(provider.getSlotsForDate('2026-01-01')![0].label, '本地专属');
  });

  test('overwrite preserves a local edit made while the remote pull waits',
      () async {
    final gate = Completer<void>();
    var gateEnabled = false;
    final provider = await _createProvider(
      failPull: false,
      dependencies: _fakeDependencies(
        failPull: false,
        pullGate: gate,
        gateDateKey: '2026-09-06',
        shouldGate: () => gateEnabled,
      ),
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
    );
    addTearDown(provider.dispose);
    gateEnabled = true;

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    provider.assignCategoryToSlots(
      {0},
      Category(name: '拉取期间编辑', color: Colors.green),
      date: DateTime(2026, 9, 6),
    );
    gate.complete();

    expect(await overwrite, isFalse);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '拉取期间编辑');
  });

  test('overwrite rejects a pull whose SHA differs from the listed SHA',
      () async {
    final provider = await _createProvider(
      failPull: false,
      dependencies: _fakeDependencies(failPull: false, pullSha: 'changed-sha'),
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
    );
    addTearDown(provider.dispose);

    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    expect(provider.getSlotsForDate('2026-01-01')![0].label, '本地专属');
  });

  test('overwrite save failure preserves slots, undo, pending, and storage',
      () async {
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: _localPreferences,
      saveDataOverride: () async => false,
    );
    addTearDown(provider.dispose);

    final beforeStorage =
        (await SharedPreferences.getInstance()).getString('daily_slots');
    final original = provider.getSlotsForDate('2026-09-06')![0].label;
    provider.assignCategoryToSlots(
      {0},
      Category(name: '覆盖前编辑', color: Colors.blue),
      date: DateTime(2026, 9, 6),
    );
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '覆盖前编辑');

    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    provider.undo();
    expect(provider.getSlotsForDate('2026-09-06')![0].label, original);
    expect(provider.pendingGiteeSyncDates, {'2026-01-01', '2026-09-06'});
    expect(provider.pendingGoogleSyncDates, {'2026-09-06', '2026-10-01'});
    expect((await SharedPreferences.getInstance()).getString('daily_slots'),
        beforeStorage);
  });

  test('overwrite aborts when a local edit changes revision during save',
      () async {
    final saveStarted = Completer<void>();
    final releaseSave = Completer<void>();
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
      saveDataOverride: () async {
        if (!saveStarted.isCompleted) saveStarted.complete();
        await releaseSave.future;
        return true;
      },
    );
    addTearDown(provider.dispose);

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await saveStarted.future;
    provider.assignCategoryToSlots(
      {0},
      Category(name: '保存期间编辑', color: Colors.orange),
      date: DateTime(2026, 9, 6),
    );
    releaseSave.complete();

    expect(await overwrite, isFalse);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '保存期间编辑');
  });

  test('overwrite aborts when identity changes during save', () async {
    final saveStarted = Completer<void>();
    final releaseSave = Completer<void>();
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
      saveDataOverride: () async {
        if (!saveStarted.isCompleted) saveStarted.complete();
        await releaseSave.future;
        return true;
      },
    );
    addTearDown(provider.dispose);

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await saveStarted.future;
    await provider.setScheduleUser(DiaryKind.j);
    releaseSave.complete();

    expect(await overwrite, isFalse);
    expect(provider.scheduleUser, DiaryKind.j);
    expect(provider.getSlotsForDate('2026-01-01')![0].label, '本地专属');
  });

  test(
      'overwrite restores every persisted key when identity changes after first write',
      () async {
    late TimeProvider provider;
    var switchedIdentity = false;
    provider = await _createProvider(
      failPull: false,
      initialPreferences: _localPreferences,
      scheduleSnapshotWriteObserver: (key) {
        if (key == 'daily_slots' && !switchedIdentity) {
          switchedIdentity = true;
          unawaited(provider.setScheduleUser(DiaryKind.j));
        }
      },
    );
    addTearDown(provider.dispose);

    final prefs = await SharedPreferences.getInstance();
    final beforeDailySlots = prefs.getString('daily_slots');
    final beforeGitee = prefs.getStringList('pending_gitee_sync_dates');
    final beforeGoogle = prefs.getStringList('pending_google_sync_dates');
    final beforeVisible = prefs.getStringList('pending_sync_dates');
    final beforeFirstDay = provider.getSlotsForDate('2026-01-01')![0].label;
    final beforeOverlapDay = provider.getSlotsForDate('2026-09-06')![0].label;
    final beforePendingGitee = Set<String>.from(provider.pendingGiteeSyncDates);
    final beforePendingGoogle =
        Set<String>.from(provider.pendingGoogleSyncDates);

    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(prefs.getString('daily_slots'), beforeDailySlots);
    expect(prefs.getStringList('pending_gitee_sync_dates'), beforeGitee);
    expect(prefs.getStringList('pending_google_sync_dates'), beforeGoogle);
    expect(prefs.getStringList('pending_sync_dates'), beforeVisible);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
    expect(provider.getSlotsForDate('2026-01-01')![0].label, beforeFirstDay);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, beforeOverlapDay);
    expect(provider.pendingGiteeSyncDates, beforePendingGitee);
    expect(provider.pendingGoogleSyncDates, beforePendingGoogle);
  });

  test('overwrite rolls back when identity changes before journal cleanup',
      () async {
    late TimeProvider provider;
    var changedIdentity = false;
    provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
      scheduleSnapshotJournalPhaseObserver: (phase) {
        if (phase == 'before_remove' && !changedIdentity) {
          changedIdentity = true;
          unawaited(provider.setScheduleUser(DiaryKind.j));
        }
      },
    );
    addTearDown(provider.dispose);

    final backup = provider.toBackupMap();
    backup['dailySlots'] =
        jsonDecode(_localPreferences['daily_slots']! as String);
    backup['pendingGiteeSyncDates'] = [
      '2026-01-01',
      '2026-09-06',
    ];
    backup['pendingGoogleSyncDates'] = [
      '2026-09-06',
      '2026-10-01',
    ];
    backup['pendingSyncDates'] = [
      '2026-01-01',
      '2026-09-06',
      '2026-10-01',
    ];
    await provider.importBackupJson(jsonEncode(backup));

    final prefs = await SharedPreferences.getInstance();
    final beforeDailySlots = prefs.getString('daily_slots');
    final beforeGitee = prefs.getStringList('pending_gitee_sync_dates');
    final beforeGoogle = prefs.getStringList('pending_google_sync_dates');
    final beforeVisible = prefs.getStringList('pending_sync_dates');

    expect(provider.getSlotsForDate('2026-09-06')![0].label, '本地重叠');
    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(provider.scheduleUser, DiaryKind.j);
    expect(provider.getSlotsForDate('2026-01-01')![0].label, '本地专属');
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '本地重叠');
    expect(provider.pendingGiteeSyncDates, {'2026-01-01', '2026-09-06'});
    expect(provider.pendingGoogleSyncDates, {'2026-09-06', '2026-10-01'});
    expect(prefs.getString('daily_slots'), beforeDailySlots);
    expect(prefs.getStringList('pending_gitee_sync_dates'), beforeGitee);
    expect(prefs.getStringList('pending_google_sync_dates'), beforeGoogle);
    expect(prefs.getStringList('pending_sync_dates'), beforeVisible);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
  });

  test('overwrite publishes failure and final schedule status', () async {
    final provider = await _createProvider(failPull: true);
    addTearDown(provider.dispose);
    final statuses = <String>[];
    final subscription = provider.scheduleGiteeSyncStream.listen(statuses.add);
    addTearDown(subscription.cancel);

    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(statuses, contains('覆盖拉取中...'));
    expect(statuses, contains('覆盖拉取失败'));
    expect(statuses.last, '');
  });

  test('failed journal cleanup keeps committed data recoverable on restart',
      () async {
    var removeAttempts = 0;
    var giteeUploads = 0;
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
      scheduleSnapshotJournalRemoveOverride: () async {
        removeAttempts++;
        return false;
      },
      dependencies: _fakeDependencies(
        failPull: false,
        onGiteeUpload: () => giteeUploads++,
      ),
    );
    addTearDown(provider.dispose);

    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    expect(removeAttempts, 1);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    final prefs = await SharedPreferences.getInstance();
    final journal = jsonDecode(
      prefs.getString('schedule_overwrite_transaction_journal')!,
    ) as Map<String, dynamic>;
    expect(journal['phase'], 'committed');

    // A committed journal with failed cleanup blocks the ordinary save.  The
    // in-memory edit is allowed for UI continuity, but it must not overwrite
    // the journal's `after` snapshot on disk.
    provider.assignCategoryToSlots(
      {0},
      Category(name: '清理失败后的编辑', color: Colors.red),
      date: DateTime(2026, 9, 6),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(giteeUploads, 0);
    expect(
      jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
      '远端',
    );
    expect(
      jsonDecode(
          prefs.getString('schedule_overwrite_transaction_journal')!)['phase'],
      'committed',
    );

    final restarted = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(
        failPull: false,
        onGiteeUpload: () => giteeUploads++,
      ),
    );
    addTearDown(restarted.dispose);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        !restarted.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(restarted.hasInitializationFailure, isFalse);
    expect(restarted.getSlotsForDate('2026-09-06')![0].label, '远端');
    expect(
      prefs.getString('schedule_overwrite_transaction_journal'),
      isNull,
    );
    expect(giteeUploads, 0);
  });

  test('identity change after real journal remove keeps committed data clean',
      () async {
    late TimeProvider provider;
    final removeStarted = Completer<void>();
    final releaseRemove = Completer<void>();
    provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
      scheduleSnapshotJournalRemoveOverride: () async {
        removeStarted.complete();
        await releaseRemove.future;
        final prefs = await SharedPreferences.getInstance();
        final remove = prefs.remove('schedule_overwrite_transaction_journal');
        await provider.setScheduleUser(DiaryKind.j);
        return remove;
      },
    );
    addTearDown(provider.dispose);

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await removeStarted.future;
    releaseRemove.complete();
    expect(await overwrite, isTrue);
    expect(provider.scheduleUser, DiaryKind.j);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
      '远端',
    );
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);

    final restarted = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(failPull: false),
    );
    addTearDown(restarted.dispose);
    while (!restarted.isInitialLoadFinished) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(restarted.hasInitializationFailure, isFalse);
    expect(restarted.getSlotsForDate('2026-09-06')![0].label, '远端');
  });

  test('slot revision change after real journal remove keeps clean snapshot',
      () async {
    late TimeProvider provider;
    final removeStarted = Completer<void>();
    final releaseRemove = Completer<void>();
    provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
      scheduleSnapshotJournalRemoveOverride: () async {
        removeStarted.complete();
        await releaseRemove.future;
        final prefs = await SharedPreferences.getInstance();
        final removed =
            await prefs.remove('schedule_overwrite_transaction_journal');
        provider.assignCategoryToSlots(
          {0},
          Category(name: '清理阶段编辑', color: Colors.purple),
          date: DateTime(2026, 9, 6),
        );
        return removed;
      },
    );
    addTearDown(provider.dispose);

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await removeStarted.future;
    releaseRemove.complete();

    expect(await overwrite, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
    expect(provider.hasInitializationFailure, isFalse);
    expect(
      jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
      '清理阶段编辑',
    );
  });

  test('cleanup failure blocks Google upload after the debounce window',
      () async {
    var giteeUploads = 0;
    var googleUploads = 0;
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
      scheduleGiteeDebounce: const Duration(milliseconds: 20),
      googleCalendarDebounce: const Duration(milliseconds: 20),
      googleCalendarSyncPlatformOverride: true,
      googleCalendarSignedInOverride: true,
      scheduleSnapshotJournalRemoveOverride: () async => false,
      dependencies: _fakeDependencies(
        failPull: false,
        onGiteeUpload: () => giteeUploads++,
        onGoogleUpload: () => googleUploads++,
      ),
    );
    addTearDown(provider.dispose);

    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    provider.assignCategoryToSlots(
      {0},
      Category(name: '清理失败后不得上传', color: Colors.red),
      date: DateTime(2026, 9, 6),
    );
    await provider.synchronizeCalendar(delay: false);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(giteeUploads, 0);
    expect(googleUploads, 0);
  });

  test('google debounce callback is invalidated by an overwrite epoch',
      () async {
    var googleUploads = 0;
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
      googleCalendarDebounce: const Duration(milliseconds: 20),
      googleCalendarSyncPlatformOverride: true,
      googleCalendarSignedInOverride: true,
      dependencies: _fakeDependencies(
        failPull: false,
        onGoogleUpload: () => googleUploads++,
      ),
    );
    addTearDown(provider.dispose);

    await provider.synchronizeCalendar(delay: true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(googleUploads, 0);
  });

  testWidgets(
      'desktop drawer exposes overwrite pull separately and acknowledges it after closing',
      (tester) async {
    final provider = TimeProvider();
    addTearDown(provider.dispose);
    final scaffoldKey = GlobalKey<ScaffoldState>();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            key: scaffoldKey,
            drawer: ProfileSettingsDrawer(onChanged: () {}),
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('拉取所有日程'), findsOneWidget);
    expect(find.text('覆盖拉取日程'), findsOneWidget);
    expect(find.text('以远端补零路径为准，清空本地旧日程，不合并'), findsOneWidget);
    final overwriteTile = find.ancestor(
      of: find.text('覆盖拉取日程'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(
        of: overwriteTile,
        matching: find.byIcon(Icons.cloud_download_outlined),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('覆盖拉取日程'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('覆盖拉取未开始：请先选择身份'), findsOneWidget);
    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
  });

  testWidgets(
      'mobile drawer exposes overwrite pull and reports rejection after closing',
      (tester) async {
    final provider = TimeProvider();
    addTearDown(provider.dispose);
    final scaffoldKey = GlobalKey<ScaffoldState>();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            key: scaffoldKey,
            drawer: ProfileSettingsDrawer(
              onChanged: () {},
              desktopPlatformOverride: false,
            ),
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('拉取所有日程'), findsNothing);
    expect(find.text('覆盖拉取日程'), findsOneWidget);

    await tester.tap(find.text('覆盖拉取日程'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('覆盖拉取未开始：请先选择身份'), findsOneWidget);
    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
  });
}
