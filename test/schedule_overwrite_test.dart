import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/services/google_calendar_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_overwrite.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/app_log_service.dart';
import 'package:time_manager/widgets/profile_settings_drawer.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_log_store.dart';

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

/// 远端日程夹具里那个时间块的颜色。
///
/// 必须是 `0xFF` 开头的不透明 ARGB：时间块颜色只可能来自分类色，
/// 而分类色在所有入口（十六进制输入框、`Category/Target/CheckInGoal.fromJson`、
/// 以及读取 `daily_slots` 时）都已统一把 alpha 收成 FF —— 半透明的块底色会让
/// 上面的文字对比度取决于它压在什么上面，见 `AppSemanticColors.opaque`。
const int kRemoteSlotColorArgb = 0xFF9CB86A;

const _remoteCanonicalContent =
    '{"updated_at":2000,"slots":[{"i":0,"l":"远端","c":$kRemoteSlotColorArgb,"cid":"g-category","ts":2000}]}';

ScheduleSyncDependencies _fakeDependencies({
  required bool failPull,
  Completer<void>? pullGate,
  int gateOnPullNumber = 1,
  String? gateDateKey,
  bool Function()? shouldGate,
  Completer<void>? googlePullGate,
  void Function()? onListPaths,
  Completer<void>? listPathsGate,
  void Function()? onPullDay,
  void Function()? onGooglePull,
  void Function()? onGiteeUpload,
  void Function()? onGoogleUpload,
  String? pullSha,
  Map<String, String>? pathShaMap,
  bool Function()? shouldPull,
}) {
  var pullCount = 0;
  return ScheduleSyncDependencies(
    loadToken: () async => 'fake-token',
    listPaths: ({required token, required userCode}) async {
      onListPaths?.call();
      if (listPathsGate != null) await listPathsGate.future;
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
      if (!(shouldPull?.call() ?? true)) {
        return ScheduleGiteePullResult.error('测试禁止读取');
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
  AppLogService? appLogService,
  Future<Object?> Function(MethodCall call)? secureStorageHandler,
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
    secureStorageHandler ?? (call) async => null,
  );

  final provider = TimeProvider(
    scheduleGiteeDebounce: scheduleGiteeDebounce,
    googleCalendarDebounce: googleCalendarDebounce,
    googleCalendarSyncPlatformOverride: googleCalendarSyncPlatformOverride,
    googleCalendarSignedInOverride: googleCalendarSignedInOverride,
    scheduleSyncDependencies:
        dependencies ?? _fakeDependencies(failPull: failPull),
    appLogService: appLogService,
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

class _RejectScheduleUserPreferenceStore
    extends InMemorySharedPreferencesStore {
  // The superclass exposes only a named constructor, so this cannot use a
  // Dart super-parameter without changing the test store's construction.
  // ignore: use_super_parameters
  _RejectScheduleUserPreferenceStore(Map<String, Object> data)
      : super.withData(data);

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.schedule_user_kind') {
      return Future<bool>.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('全量拉取会记录成功日志并保留完成进度', () async {
    final logs = AppLogService(store: FakeAppLogStore());
    await logs.initialize();
    final provider = await _createProvider(
      failPull: false,
      appLogService: logs,
      googleCalendarSyncPlatformOverride: false,
    );
    addTearDown(provider.dispose);

    await provider.pullAllSchedulesFromGitee();

    final progress = provider.scheduleSyncProgress;
    expect(progress, isNotNull);
    expect(progress!.message, '全部拉取完成 (1 天)');
    expect(progress.completed, 1);
    expect(progress.total, 1);
    expect(progress.isFinished, isTrue);
    expect(
      logs.entries.map((entry) => entry.message),
      containsAll(<String>[
        '全量日程拉取开始（身份 g）',
        '日程拉取成功：2026-09-06（远端 1 条，合并后 1 条）',
        '全量日程拉取完成：1/1 天',
      ]),
    );
  });

  test('覆盖拉取会发布逐阶段进度并记录远端快照结果', () async {
    final logs = AppLogService(store: FakeAppLogStore());
    await logs.initialize();
    final provider = await _createProvider(
      failPull: false,
      appLogService: logs,
      googleCalendarSyncPlatformOverride: false,
    );
    addTearDown(provider.dispose);

    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);

    final progress = provider.scheduleSyncProgress;
    expect(progress, isNotNull);
    expect(progress!.message, '覆盖拉取完成');
    expect(progress.completed, 1);
    expect(progress.total, 1);
    expect(progress.isFinished, isTrue);
    expect(
      logs.entries.map((entry) => entry.message),
      containsAll(<String>[
        '覆盖拉取开始（身份 g）',
        '覆盖拉取远端文件列表完成：1 个文件',
        '覆盖拉取完成：1/1 天',
      ]),
    );
  });

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
    expect(replaced[0].color?.toARGB32(), kRemoteSlotColorArgb);
    // 颜色经过覆盖落盘/读回后仍然不透明
    expect(replaced[0].color?.a, 1.0);
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
    expect(provider.slots, isEmpty);

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

    expect(provider.slots, isEmpty);
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

  test('schedule access is safe while initialization runs and import waits',
      () async {
    SharedPreferences.setMockInitialValues({
      'daily_slots': _localPreferences['daily_slots']!,
    });
    var saveCalls = 0;
    final provider = TimeProvider(
      saveDataOverride: () async {
        saveCalls++;
        return true;
      },
      scheduleSyncDependencies: _fakeDependencies(failPull: false),
    );
    addTearDown(provider.dispose);

    var notificationCount = 0;
    provider.addListener(() => notificationCount++);

    expect(provider.slots, hasLength(144));
    expect(provider.slots.every((slot) => !slot.recorded), isTrue);
    expect(provider.slotsForDate(DateTime(2099, 1, 1)), hasLength(144));
    expect(
      provider
          .slotsForDate(DateTime(2099, 1, 1))
          .every((slot) => !slot.recorded),
      isTrue,
    );
    expect(provider.getSlotsForDate('2099-01-01'), isNull);
    provider.toggleSlot(0);
    provider.assignCategoryToSlots(
      {0},
      Category(name: '初始化前编辑', color: Colors.red),
      date: DateTime(2099, 1, 1),
    );
    provider.addCategory(Category(name: '初始化前分类', color: Colors.blue));
    provider.setCategoryExpandState('initialization', false);
    final import = provider.importBackupJson(
      jsonEncode({
        'version': 1,
        'categories': <Map<String, Object>>[],
        'dailySlots': <String, Object>{
          '2099-01-02': [
            {'i': 0, 'l': '初始化前导入'},
          ],
        },
      }),
    );
    final selectUser = provider.setScheduleUser(DiaryKind.j);

    // These calls all happen before the constructor's first async load turn.
    // Temporary render slots must not create a persisted day or allow edits.
    expect(notificationCount, 0);
    expect(provider.getSlotsForDate('2099-01-01'), isNull);
    expect(provider.getSlotsForDate('2099-01-02'), isNull);

    await Future.wait([import, selectUser]);
    while (!provider.isInitialLoadFinished) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(saveCalls, 1);
    expect(provider.scheduleUser, DiaryKind.g);
    expect(provider.getSlotsForDate('2099-01-01'), isNull);
    expect(provider.getSlotsForDate('2099-01-02')![0].label, '初始化前导入');
    expect(
      provider.categories.any((category) => category.name == '初始化前分类'),
      isFalse,
    );
  });

  test('failed initialization isolates public schedule access and mutation',
      () async {
    const corruptJournal = '{"phase":"prepared","before":';
    SharedPreferences.setMockInitialValues({
      'daily_slots': _localPreferences['daily_slots']!,
      'schedule_overwrite_transaction_journal': corruptJournal,
    });
    var saveCalls = 0;
    final provider = TimeProvider(
      saveDataOverride: () async {
        saveCalls++;
        return true;
      },
      scheduleSyncDependencies: _fakeDependencies(failPull: false),
    );
    addTearDown(provider.dispose);
    while (!provider.isInitialLoadFinished) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(provider.hasInitializationFailure, isTrue);

    var notificationCount = 0;
    provider.addListener(() => notificationCount++);
    final beforeCategories = provider.categories;
    final prefs = await SharedPreferences.getInstance();
    final beforeSlots = prefs.getString('daily_slots');

    expect(provider.slots, isEmpty);
    expect(provider.slotsForDate(DateTime(2099, 2, 1)), isEmpty);
    expect(provider.getSlotsForDate('2099-02-01'), isNull);
    provider.toggleSlot(0);
    provider.clearAll();
    provider.undo();
    provider.assignCategoryToSlots(
      {0},
      Category(name: '失败后编辑', color: Colors.green),
      date: DateTime(2099, 2, 1),
    );
    provider.removeEventFromSlot(0, date: DateTime(2099, 2, 1));
    provider.addCategory(Category(name: '失败后分类', color: Colors.orange));
    provider.setCategoryExpandState('failed', false);
    provider.addTarget(Target(
      id: 'failed-target',
      name: '失败后目标',
      type: TargetType.duration,
      color: Colors.purple,
      period: 'daily',
    ));
    await provider.importBackupJson(
      jsonEncode({
        'version': 1,
        'categories': <Map<String, Object>>[],
        'dailySlots': <String, Object>{
          '2099-02-02': [
            {'i': 0, 'l': '失败后导入'},
          ],
        },
      }),
    );
    await provider.setScheduleUser(DiaryKind.j);
    await provider.onAppBackgrounded();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(provider.slots, isEmpty);
    expect(provider.getSlotsForDate('2099-02-01'), isNull);
    expect(provider.getSlotsForDate('2099-02-02'), isNull);
    expect(provider.categories, beforeCategories);
    expect(saveCalls, 0);
    expect(notificationCount, 0);
    expect(prefs.getString('daily_slots'), beforeSlots);
  });

  test('disposed provider ignores in-flight continuation and auth callback',
      () async {
    final pullStarted = Completer<void>();
    final pullGate = Completer<void>();
    var saveCalls = 0;
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
      googleCalendarSyncPlatformOverride: true,
      googleCalendarSignedInOverride: true,
      saveDataOverride: () async {
        saveCalls++;
        return true;
      },
      dependencies: _fakeDependencies(
        failPull: false,
        googlePullGate: pullGate,
        onGooglePull: () {
          if (!pullStarted.isCompleted) pullStarted.complete();
        },
      ),
    );
    saveCalls = 0;
    var notificationCount = 0;
    provider.addListener(() => notificationCount++);

    final pull = provider.pullGoogleCalendarForDate(DateTime(2099, 3, 1));
    await pullStarted.future;
    provider.dispose();
    pullGate.complete();
    await pull;
    await GoogleCalendarService.logout();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(provider.getSlotsForDate('2099-03-01'), isNull);
    expect(saveCalls, 0);
    expect(notificationCount, 0);
  });

  test('disposed provider ignores in-flight Gitee pull continuation', () async {
    final pullStarted = Completer<void>();
    final pullGate = Completer<void>();
    var gateEnabled = false;
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': _localPreferences['daily_slots']!,
      },
      dependencies: _fakeDependencies(
        failPull: false,
        pullGate: pullGate,
        gateDateKey: '2026-09-06',
        shouldGate: () => gateEnabled,
        onPullDay: () {
          if (gateEnabled && !pullStarted.isCompleted) pullStarted.complete();
        },
      ),
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) provider.dispose();
    });
    final backup = provider.toBackupMap();
    backup['dailySlots'] =
        jsonDecode(_localPreferences['daily_slots']! as String);
    await provider.importBackupJson(jsonEncode(backup));
    final beforeLabel =
        (provider.toBackupMap()['dailySlots'] as Map)['2026-09-06'][0]['l'];
    gateEnabled = true;
    var notificationCount = 0;
    provider.addListener(() => notificationCount++);

    final pull = provider.pullScheduleFromGitee(
      date: DateTime(2026, 9, 6),
    );
    await pullStarted.future;
    // The pull now publishes its initial progress before waiting on the
    // network. Only the post-dispose continuation must remain silent.
    notificationCount = 0;
    provider.dispose();
    disposed = true;
    pullGate.complete();
    await pull;

    final slotsAfterDispose =
        (provider.toBackupMap()['dailySlots'] as Map)['2026-09-06'] as List;
    expect((slotsAfterDispose.first as Map)['l'], beforeLabel);
    expect(notificationCount, 0);
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

  test('已有普通同步时覆盖拉取会保留当前进度并提示原因', () async {
    final pullGate = Completer<void>();
    var gateEnabled = false;
    final provider = await _createProvider(
      failPull: false,
      dependencies: _fakeDependencies(
        failPull: false,
        pullGate: pullGate,
        gateDateKey: '2026-09-06',
        shouldGate: () => gateEnabled,
      ),
    );
    addTearDown(provider.dispose);
    gateEnabled = true;
    final statuses = <String>[];
    final subscription = provider.syncStatusStream.listen(statuses.add);
    addTearDown(subscription.cancel);

    final sync = provider.syncScheduleToGitee(dateKey: '2026-09-06');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(provider.scheduleSyncProgress?.message, '正在同步日程 2026-09-06');
    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);
    expect(
      statuses,
      contains('覆盖拉取未开始：已有日程同步任务'),
    );
    expect(provider.scheduleSyncProgress?.isError, isFalse);

    pullGate.complete();
    await sync;
  });

  test('同步所有日程时覆盖拉取能看到当前任务进度', () async {
    final pullGate = Completer<void>();
    var gateEnabled = false;
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        'daily_slots': '{"2026-09-06":[{"i":0,"l":"待同步","ts":1000}]}',
      },
      dependencies: _fakeDependencies(
        failPull: false,
        pullGate: pullGate,
        gateDateKey: '2026-09-06',
        shouldGate: () => gateEnabled,
      ),
    );
    addTearDown(provider.dispose);
    gateEnabled = true;

    final sync = provider.syncAllSchedulesToGitee();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(provider.scheduleSyncProgress?.message, '正在同步日程 1/1');

    pullGate.complete();
    await sync;
  });

  test('remote view transition owns its save window and rejects overwrite pull',
      () async {
    final saveStarted = Completer<void>();
    final releaseSave = Completer<void>();
    var pauseNextSave = false;
    var listPathsCalls = 0;
    var overwriteStarted = false;
    var giteeUploads = 0;
    var googlePulls = 0;
    var googleUploads = 0;

    final dependencies = ScheduleSyncDependencies(
      loadToken: () async => 'fake-token',
      listPaths: ({required token, required userCode}) async {
        listPathsCalls++;
        overwriteStarted = true;
        return ScheduleGiteeListWithShaResult.success(
          {'schedule/g/2026-09-06.json': 'remote-sha'},
        );
      },
      pullDay: ({required token, required dateKey, required userCode}) async {
        // Suppress the desktop startup pull.  The overwrite pull is enabled
        // only after listPaths, while the remote-view pull always uses J.
        if (userCode != 'j' && !overwriteStarted) {
          return ScheduleGiteePullResult.error('测试禁止读取');
        }
        return ScheduleGiteePullResult.success(
          _remoteCanonicalContent,
          'remote-sha',
        );
      },
      pushDay: ({
        required token,
        required dateKey,
        required userCode,
        required content,
        required commitMessage,
      }) async {
        giteeUploads++;
        return ScheduleGiteePushResult.success(created: false);
      },
      pushGoogleDay: (slots, date) async {
        googleUploads++;
        return true;
      },
      pullGoogleDay: (date) async {
        googlePulls++;
        return const [];
      },
    );

    final provider = await _createProvider(
      failPull: false,
      initialPreferences: _localPreferences,
      dependencies: dependencies,
      saveDataOverride: () async {
        if (pauseNextSave) {
          pauseNextSave = false;
          saveStarted.complete();
          await releaseSave.future;
        }
        return true;
      },
    );
    addTearDown(provider.dispose);

    final prefs = await SharedPreferences.getInstance();
    final beforeSlots = prefs.getString('daily_slots');
    final beforeGiteePending = prefs.getStringList('pending_gitee_sync_dates');
    final beforeGooglePending =
        prefs.getStringList('pending_google_sync_dates');
    final beforePending = prefs.getStringList('pending_sync_dates');
    pauseNextSave = true;

    final remoteView = provider.toggleRemoteScheduleView();
    await saveStarted.future;

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    expect(await overwrite, isFalse);
    expect(
      provider.lastScheduleOverwriteFailure,
      '覆盖拉取未开始：远程视图切换进行中',
    );
    expect(listPathsCalls, 0);
    expect(provider.isRemoteViewEnabled, isFalse);

    provider.assignCategoryToSlots(
      {0},
      Category(name: '切换期间编辑', color: Colors.red),
      date: DateTime(2026, 9, 6),
    );
    await provider.onAppBackgrounded();
    await provider.syncScheduleToGitee(dateKey: '2026-09-06');
    await provider.pullGoogleCalendarForDate(DateTime(2026, 9, 6));
    await provider.setScheduleUser(DiaryKind.j);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '本地重叠');
    expect(provider.scheduleUser, DiaryKind.g);
    expect(giteeUploads, 0);
    expect(googlePulls, 0);
    expect(googleUploads, 0);

    releaseSave.complete();
    await remoteView;

    expect(provider.isRemoteViewEnabled, isTrue);
    expect(listPathsCalls, 0);
    expect(prefs.getString('daily_slots'), beforeSlots);
    expect(prefs.getStringList('pending_gitee_sync_dates'), beforeGiteePending);
    expect(
        prefs.getStringList('pending_google_sync_dates'), beforeGooglePending);
    expect(prefs.getStringList('pending_sync_dates'), beforePending);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
    expect(provider.slots.any((slot) => slot.label == '远端'), isTrue);
  });

  test('remote view blocks ordinary persistence, sync, identity, and overwrite',
      () async {
    var giteeUploads = 0;
    var googlePulls = 0;
    var googleUploads = 0;
    var saveCalls = 0;
    final dependencies = ScheduleSyncDependencies(
      loadToken: () async => 'fake-token',
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.success(
        {'schedule/g/2026-09-06.json': 'remote-sha'},
      ),
      pullDay: ({required token, required dateKey, required userCode}) async {
        if (userCode != 'j') return ScheduleGiteePullResult.error('禁止读取');
        return ScheduleGiteePullResult.success(
          _remoteCanonicalContent,
          'remote-sha',
        );
      },
      pushDay: ({
        required token,
        required dateKey,
        required userCode,
        required content,
        required commitMessage,
      }) async {
        giteeUploads++;
        return ScheduleGiteePushResult.success(created: false);
      },
      pullGoogleDay: (date) async {
        googlePulls++;
        return const [];
      },
      pushGoogleDay: (slots, date) async {
        googleUploads++;
        return true;
      },
    );
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: _localPreferences,
      dependencies: dependencies,
      saveDataOverride: () async {
        saveCalls++;
        return true;
      },
      googleCalendarSyncPlatformOverride: true,
      googleCalendarSignedInOverride: true,
    );
    addTearDown(provider.dispose);
    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final prefs = await SharedPreferences.getInstance();
    final diskBefore = prefs.getString('daily_slots');

    await provider.toggleRemoteScheduleView();
    expect(provider.isRemoteViewEnabled, isTrue);
    final savesAfterOpen = saveCalls;
    final googlePullsAfterOpen = googlePulls;

    provider.assignCategoryToSlots(
      {0},
      Category(name: '远程视图编辑', color: Colors.red),
      date: DateTime(2026, 9, 6),
    );
    await provider.onAppBackgrounded();
    await provider.syncScheduleToGitee(dateKey: '2026-09-06');
    await provider.syncAllSchedulesToGitee();
    await provider.pullAllSchedulesFromGitee();
    expect(await provider.pullScheduleFromGitee(), isFalse);
    await provider.pullGoogleCalendarForDate(DateTime(2026, 9, 6));
    await provider.synchronizeCalendar(delay: false);
    await provider.synchronizeAllPendingCalendars();
    await provider.setScheduleUser(DiaryKind.j);
    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);

    expect(provider.scheduleUser, DiaryKind.g);
    expect(saveCalls, savesAfterOpen);
    expect(googlePulls, googlePullsAfterOpen);
    expect(giteeUploads, 0);
    expect(googleUploads, 0);
    expect(prefs.getString('daily_slots'), diskBefore);
    expect(provider.slots.any((slot) => slot.label == '远程视图编辑'), isFalse);
  });

  test('remote view close save failure keeps backup and remote memory',
      () async {
    var failSave = false;
    final dependencies = ScheduleSyncDependencies(
      loadToken: () async => 'fake-token',
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.success(const {}),
      pullDay: ({required token, required dateKey, required userCode}) async {
        if (userCode != 'j') return ScheduleGiteePullResult.error('禁止读取');
        return ScheduleGiteePullResult.success(
          _remoteCanonicalContent,
          'remote-sha',
        );
      },
    );
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: _localPreferences,
      dependencies: dependencies,
      saveDataOverride: () async => !failSave,
    );
    addTearDown(provider.dispose);
    provider.goToDate(DateTime(2026, 9, 6));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final prefs = await SharedPreferences.getInstance();
    final localDisk = prefs.getString('daily_slots');

    await provider.toggleRemoteScheduleView();
    expect(provider.isRemoteViewEnabled, isTrue);
    expect(provider.slots[0].label, '远端');

    failSave = true;
    await provider.toggleRemoteScheduleView();
    expect(provider.isRemoteViewEnabled, isTrue);
    expect(provider.slots[0].label, '远端');
    expect(prefs.getString('daily_slots'), localDisk);

    failSave = false;
    await provider.toggleRemoteScheduleView();
    expect(provider.isRemoteViewEnabled, isFalse);
    expect(provider.slots[0].label, '本地重叠');
    expect(jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
        '本地重叠');
  });

  test('rejects identity change during overwrite fetch', () async {
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
    provider.assignCategoryToSlots(
      {0},
      Category(name: '覆盖前本地', color: Colors.blue),
      date: DateTime(2026, 9, 6),
    );
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '覆盖前本地');
    gateEnabled = true;

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final attemptedIdentity = provider.setScheduleUser(DiaryKind.j);
    await attemptedIdentity;
    expect(provider.scheduleUser, DiaryKind.g);
    gate.complete();

    expect(await overwrite, isTrue);
    expect(provider.scheduleUser, DiaryKind.g);
    expect(provider.getSlotsForDate('2026-01-01'), isNull);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule_user_kind'), 'g');
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
  });

  test('identity persistence claims the namespace before overwrite can start',
      () async {
    final manualWriteStarted = Completer<void>();
    final releaseManualWrite = Completer<void>();
    var blockManualWrite = false;
    var listPathsCalls = 0;
    var pullDayCalls = 0;
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {
        ..._localPreferences,
        'schedule_user_kind': 'g',
      },
      dependencies: _fakeDependencies(
        failPull: false,
        onListPaths: () => listPathsCalls++,
        onPullDay: () => pullDayCalls++,
        shouldPull: () => false,
      ),
      secureStorageHandler: (call) async {
        final arguments = call.arguments;
        final isManualKind = arguments is Map &&
            arguments['key'] == 'app_user_identity_manual_kind';
        if (call.method == 'read' && isManualKind) return 'g';
        if (call.method == 'write' && isManualKind && blockManualWrite) {
          if (!manualWriteStarted.isCompleted) {
            manualWriteStarted.complete();
          }
          await releaseManualWrite.future;
        }
        return null;
      },
    );
    addTearDown(provider.dispose);
    listPathsCalls = 0;
    pullDayCalls = 0;

    final prefs = await SharedPreferences.getInstance();
    final beforeSlots = prefs.getString('daily_slots');
    blockManualWrite = true;
    final setter = provider.setScheduleUser(DiaryKind.j);
    await manualWriteStarted.future;

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    expect(await overwrite, isFalse);
    expect(provider.scheduleUser, DiaryKind.g);
    expect(prefs.getString('schedule_user_kind'), 'g');
    expect(prefs.getString('daily_slots'), beforeSlots);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
    expect(listPathsCalls, 0);
    expect(pullDayCalls, 0);
    expect(provider.getSlotsForDate('2026-01-01')![0].label, '本地专属');
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '本地重叠');

    releaseManualWrite.complete();
    await setter;
    expect(provider.scheduleUser, DiaryKind.j);
    expect(prefs.getString('schedule_user_kind'), 'j');
    expect(prefs.getString('daily_slots'), beforeSlots);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
  });

  test(
      'first identity selection clears secure manual kind when preferences reject it',
      () async {
    final store = _RejectScheduleUserPreferenceStore({
      'flutter.daily_slots': _localPreferences['daily_slots']!,
    });
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();

    String? secureManualKind;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final secureStorageChannel = const MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      secureStorageChannel,
      (call) async {
        final arguments = call.arguments;
        final isManualKind = arguments is Map &&
            arguments['key'] == 'app_user_identity_manual_kind';
        if (!isManualKind) return null;
        if (call.method == 'read') return secureManualKind;
        if (call.method == 'write') {
          secureManualKind = arguments['value'] as String;
        } else if (call.method == 'delete') {
          secureManualKind = null;
        }
        return null;
      },
    );

    final provider = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(failPull: false),
    );
    TimeProvider? restarted;
    addTearDown(() {
      provider.dispose();
      restarted?.dispose();
      messenger.setMockMethodCallHandler(secureStorageChannel, null);
      SharedPreferences.resetStatic();
    });

    while (!provider.isInitialLoadFinished) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(provider.hasSelectedScheduleUser, isFalse);

    await provider.setScheduleUser(DiaryKind.j);

    expect(provider.scheduleUser, DiaryKind.g);
    expect(provider.hasSelectedScheduleUser, isFalse);
    expect(secureManualKind, isNull);
    final prefsAfterFailure = await SharedPreferences.getInstance();
    expect(prefsAfterFailure.getString('schedule_user_kind'), isNull);

    // Recreate both provider and SharedPreferences facade.  The failed first
    // selection must not reappear from secure storage on the next load.
    SharedPreferences.resetStatic();
    restarted = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(failPull: false),
    );
    while (!restarted.isInitialLoadFinished) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(restarted.scheduleUser, DiaryKind.g);
    expect(restarted.hasSelectedScheduleUser, isFalse);
    expect(secureManualKind, isNull);
  });

  test('waits for identity loading before schedule sync and overwrite',
      () async {
    final identityLoadStarted = Completer<void>();
    final releaseIdentityLoad = Completer<void>();
    var listPathsCalls = 0;
    var pullDayCalls = 0;
    SharedPreferences.setMockInitialValues({
      ..._localPreferences,
      'schedule_user_kind': 'g',
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final arguments = call.arguments;
        final isManualKind = arguments is Map &&
            arguments['key'] == 'app_user_identity_manual_kind';
        if (call.method == 'read' && isManualKind) {
          if (!identityLoadStarted.isCompleted) {
            identityLoadStarted.complete();
          }
          await releaseIdentityLoad.future;
          return 'g';
        }
        return null;
      },
    );
    final provider = TimeProvider(
      scheduleSyncDependencies: _fakeDependencies(
        failPull: false,
        onListPaths: () => listPathsCalls++,
        onPullDay: () => pullDayCalls++,
      ),
    );
    addTearDown(() {
      if (!releaseIdentityLoad.isCompleted) releaseIdentityLoad.complete();
      provider.dispose();
    });

    await identityLoadStarted.future;
    while (!provider.isInitialLoadFinished) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final prefs = await SharedPreferences.getInstance();
    final beforeSlots = prefs.getString('daily_slots');

    await provider.setScheduleUser(DiaryKind.g);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await provider.syncScheduleToGitee(dateKey: '2026-09-06');
    expect(await provider.overwriteAllSchedulesFromGitee(), isFalse);

    expect(listPathsCalls, 0);
    expect(pullDayCalls, 0);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '本地重叠');
    expect(prefs.getString('daily_slots'), beforeSlots);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);

    releaseIdentityLoad.complete();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!provider.hasSelectedScheduleUser &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(provider.scheduleUser, DiaryKind.g);
    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);
    expect(listPathsCalls, greaterThan(0));
    expect(pullDayCalls, greaterThan(0));
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    expect(
      jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
      '远端',
    );
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
  });

  test('overwrite rejects a local edit made while the remote pull waits',
      () async {
    final gate = Completer<void>();
    final listPathsGate = Completer<void>();
    final overwriteListed = Completer<void>();
    var gateEnabled = false;
    final provider = await _createProvider(
      failPull: false,
      dependencies: _fakeDependencies(
        failPull: false,
        onListPaths: () {
          if (!overwriteListed.isCompleted) overwriteListed.complete();
        },
        listPathsGate: listPathsGate,
        pullGate: gate,
        gateDateKey: '2026-09-06',
        shouldGate: () => gateEnabled,
      ),
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
    );
    addTearDown(provider.dispose);
    provider.assignCategoryToSlots(
      {0},
      Category(name: '覆盖前本地', color: Colors.blue),
      date: DateTime(2026, 9, 6),
    );
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '覆盖前本地');
    gateEnabled = true;

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await overwriteListed.future;
    provider.assignCategoryToSlots(
      {0},
      Category(name: '拉取期间编辑', color: Colors.green),
      date: DateTime(2026, 9, 6),
    );
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '覆盖前本地');
    listPathsGate.complete();
    gate.complete();

    expect(await overwrite, isTrue);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
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

  test('overwrite rejects a local edit during save and commits remote snapshot',
      () async {
    late TimeProvider provider;
    var editAttempted = false;
    late SharedPreferences prefs;

    provider = await _createProvider(
      failPull: false,
      initialPreferences: _localPreferences,
      scheduleSnapshotWriteObserver: (key) {
        if (key != 'daily_slots' || editAttempted) return;
        editAttempted = true;

        // The real overwrite save has reached its first snapshot write.  The
        // provider must still reject a local mutation while the transaction is
        // active, without changing either state from the moment of the edit
        // attempt.  (The overwrite may have already persisted its candidate
        // before publishing it to memory.)
        final memoryBeforeEdit =
            provider.getSlotsForDate('2026-09-06')![0].label;
        final revisionBeforeEdit = provider.slotsRevision;
        final diskSlotsBeforeEdit = prefs.getString('daily_slots');
        final diskGiteePendingBeforeEdit =
            prefs.getStringList('pending_gitee_sync_dates');
        final diskGooglePendingBeforeEdit =
            prefs.getStringList('pending_google_sync_dates');
        final diskPendingBeforeEdit = prefs.getStringList('pending_sync_dates');
        final giteePendingBeforeEdit = {...provider.pendingGiteeSyncDates};
        final googlePendingBeforeEdit = {...provider.pendingGoogleSyncDates};

        provider.assignCategoryToSlots(
          {0},
          Category(name: '保存期间编辑', color: Colors.orange),
          date: DateTime(2026, 9, 6),
        );

        expect(
            provider.getSlotsForDate('2026-09-06')![0].label, memoryBeforeEdit);
        expect(provider.slotsRevision, revisionBeforeEdit);
        expect(prefs.getString('daily_slots'), diskSlotsBeforeEdit);
        expect(prefs.getStringList('pending_gitee_sync_dates'),
            diskGiteePendingBeforeEdit);
        expect(prefs.getStringList('pending_google_sync_dates'),
            diskGooglePendingBeforeEdit);
        expect(
            prefs.getStringList('pending_sync_dates'), diskPendingBeforeEdit);
        expect(provider.pendingGiteeSyncDates, giteePendingBeforeEdit);
        expect(provider.pendingGoogleSyncDates, googlePendingBeforeEdit);
      },
    );
    addTearDown(provider.dispose);
    prefs = await SharedPreferences.getInstance();

    final overwritten = await provider.overwriteAllSchedulesFromGitee();

    expect(editAttempted, isTrue);
    expect(overwritten, isTrue);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    expect(provider.getSlotsForDate('2026-01-01'), isNull);

    final diskSlots = jsonDecode(prefs.getString('daily_slots')!);
    expect(diskSlots['2026-09-06'][0]['l'], '远端');
    expect(diskSlots.containsKey('2026-01-01'), isFalse);
    expect(provider.pendingGiteeSyncDates, isEmpty);
    expect(provider.pendingGoogleSyncDates, isEmpty);
    expect(provider.pendingSyncDates, isEmpty);
    expect(prefs.getStringList('pending_gitee_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_google_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_sync_dates'), isEmpty);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
  });

  test('rejects identity change during overwrite save', () async {
    final saveStarted = Completer<void>();
    final releaseSave = Completer<void>();
    var overwriteStarted = false;
    late TimeProvider provider;
    provider = await _createProvider(
      failPull: false,
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
      saveDataOverride: () async {
        if (!overwriteStarted) return true;
        if (!saveStarted.isCompleted) saveStarted.complete();
        await releaseSave.future;
        return true;
      },
    );
    addTearDown(provider.dispose);

    overwriteStarted = true;
    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await saveStarted.future;
    final attemptedIdentity = provider.setScheduleUser(DiaryKind.j);
    await attemptedIdentity;
    final prefs = await SharedPreferences.getInstance();
    expect(provider.scheduleUser, DiaryKind.g);
    expect(prefs.getString('schedule_user_kind'), 'g');
    releaseSave.complete();

    expect(await overwrite, isTrue);
    expect(provider.scheduleUser, DiaryKind.g);
    expect(provider.getSlotsForDate('2026-01-01'), isNull);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    expect(prefs.getString('schedule_user_kind'), 'g');
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
  });

  test('rejects identity change from overwrite notify listener', () async {
    final provider = await _createProvider(
      failPull: false,
      initialPreferences: {'daily_slots': _localPreferences['daily_slots']!},
    );
    addTearDown(provider.dispose);
    var attemptedIdentity = false;
    provider.addListener(() {
      if (attemptedIdentity) return;
      attemptedIdentity = true;
      unawaited(provider.setScheduleUser(DiaryKind.j));
    });

    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);
    await Future<void>.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(attemptedIdentity, isTrue);
    expect(provider.scheduleUser, DiaryKind.g);
    expect(prefs.getString('schedule_user_kind'), 'g');
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
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

    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);
    await Future<void>.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
      '远端',
    );
    expect(prefs.getStringList('pending_gitee_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_google_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_sync_dates'), isEmpty);
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
    expect(provider.getSlotsForDate('2026-01-01'), isNull);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    expect(provider.pendingGiteeSyncDates, isEmpty);
    expect(provider.pendingGoogleSyncDates, isEmpty);
    expect(provider.scheduleUser, DiaryKind.g);
    expect(prefs.getString('schedule_user_kind'), 'g');
  });

  test('rejects identity change before journal cleanup', () async {
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

    expect(provider.getSlotsForDate('2026-09-06')![0].label, '本地重叠');
    expect(await provider.overwriteAllSchedulesFromGitee(), isTrue);
    await Future<void>.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(provider.scheduleUser, DiaryKind.g);
    expect(provider.getSlotsForDate('2026-01-01'), isNull);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    expect(provider.pendingGiteeSyncDates, isEmpty);
    expect(provider.pendingGoogleSyncDates, isEmpty);
    expect(
      jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
      '远端',
    );
    expect(prefs.getStringList('pending_gitee_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_google_sync_dates'), isEmpty);
    expect(prefs.getStringList('pending_sync_dates'), isEmpty);
    expect(prefs.getString('schedule_user_kind'), 'g');
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

  test('identity change during real journal remove is rejected safely',
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
        return prefs.remove('schedule_overwrite_transaction_journal');
      },
    );
    addTearDown(provider.dispose);

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await removeStarted.future;
    final attemptedIdentity = provider.setScheduleUser(DiaryKind.j);
    expect(provider.scheduleUser, DiaryKind.g);
    releaseRemove.complete();
    await attemptedIdentity;
    expect(await overwrite, isTrue);
    expect(provider.scheduleUser, DiaryKind.g);
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
      '远端',
    );
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);

    // The rejected switch did not persist an identity while the committed
    // snapshot was being cleaned up.  It becomes retryable after the
    // transaction has finished.
    expect(prefs.getString('schedule_user_kind'), 'g');
    await provider.setScheduleUser(DiaryKind.j);
    expect(provider.scheduleUser, DiaryKind.j);
    expect(prefs.getString('schedule_user_kind'), 'j');

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

  test('slot edit during real journal remove is rejected safely', () async {
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
        return prefs.remove('schedule_overwrite_transaction_journal');
      },
    );
    addTearDown(provider.dispose);

    final overwrite = provider.overwriteAllSchedulesFromGitee();
    await removeStarted.future;
    final revisionAtRemove = provider.slotsRevision;
    provider.assignCategoryToSlots(
      {0},
      Category(name: '清理阶段编辑', color: Colors.purple),
      date: DateTime(2026, 9, 6),
    );
    expect(provider.slotsRevision, revisionAtRemove);
    releaseRemove.complete();

    expect(await overwrite, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule_overwrite_transaction_journal'), isNull);
    expect(provider.hasInitializationFailure, isFalse);
    expect(
      jsonDecode(prefs.getString('daily_slots')!)['2026-09-06'][0]['l'],
      '远端',
    );
    expect(provider.getSlotsForDate('2026-09-06')![0].label, '远端');
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

    expect(find.textContaining('覆盖拉取未开始：'), findsOneWidget);
    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('mobile drawer exposes only overwrite pull action',
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
              androidPlatformOverride: false,
            ),
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('拉取所有日程'), findsNothing);
    expect(find.text('推送所有日程'), findsNothing);
    expect(find.text('覆盖拉取日程'), findsOneWidget);
  });
}
