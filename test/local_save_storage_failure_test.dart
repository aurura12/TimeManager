import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/providers/background_image_provider.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/providers/desktop_shortcut_provider.dart';
import 'package:time_manager/providers/main_tab_provider.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'package:time_manager/models/check_in_document.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/known_google_users.dart';
import 'package:time_manager/models/travel_record.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/check_in_local_store.dart';
import 'package:time_manager/services/check_in_sync_service.dart';
import 'package:time_manager/services/diary_local_store.dart';
import 'package:time_manager/services/on_this_day_service.dart';
import 'package:time_manager/services/travel_local_store.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/data_failure_banner.dart';

/// 真实存储失败的验收测试。
///
/// `failure_banner_test.dart` 用 `saveDataOverride` 注入，绕开了 SharedPreferences 本身。
/// 这里换成真的写盘平台：`daily_slots` 的 setValue 返回 false / 抛 PlatformException，
/// 走的就是线上"磁盘满、无写权限"那条路。

class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    return null;
  }

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
  ) async {
    return null;
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<void> clearAuthorizationToken(
      ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

/// 只让 `daily_slots` 写失败，其余偏好正常——模拟"磁盘满"时最先写丢的是时间块。
/// 所有写入都失败，但读取正常——模拟「磁盘满」时各模块的本地保存结果。
class _FailingWritesStore extends InMemorySharedPreferencesStore {
  // ignore: use_super_parameters
  _FailingWritesStore(Map<String, Object> data) : super.withData(data);

  bool throwOnWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (throwOnWrite) {
      throw PlatformException(code: 'disk-full', message: 'No space left on device');
    }
    return false;
  }
}

class _DelayedTravelFailureStore extends InMemorySharedPreferencesStore {
  _DelayedTravelFailureStore(super.data) : super.withData();

  final started = Completer<void>();
  final release = Completer<void>();
  bool _firstWrite = true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('travel_records_draft') && _firstWrite) {
      _firstWrite = false;
      started.complete();
      await release.future;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class _FailingSlotWriteStore extends InMemorySharedPreferencesStore {
  // ignore: use_super_parameters
  _FailingSlotWriteStore(Map<String, Object> data) : super.withData(data);

  bool failSlotWrites = false;
  bool throwOnSlotWrite = false;
  int slotWriteAttempts = 0;
  int slotWritesPersisted = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('daily_slots')) {
      slotWriteAttempts++;
      if (throwOnSlotWrite) {
        throw PlatformException(
          code: 'disk-full',
          message: 'No space left on device',
        );
      }
      if (failSlotWrites) return false;
      final result = await super.setValue(valueType, key, value);
      if (result) slotWritesPersisted++;
      return result;
    }
    return super.setValue(valueType, key, value);
  }
}

ScheduleSyncDependencies _offlineDependencies() => ScheduleSyncDependencies(
      loadToken: () async => 'fake-token',
      listPaths: ({required token, required userCode}) async =>
          ScheduleGiteeListWithShaResult.error('测试禁用远端'),
      pullDay: ({required token, required dateKey, required userCode}) async =>
          ScheduleGiteePullResult.error('测试禁用远端'),
    );

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

void _installPluginMocks() {
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
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_storage_failure_test',
  );
}

Future<TimeProvider> _waitLoaded(TimeProvider provider) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(provider.isInitialLoadFinished, isTrue);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return provider;
}

/// 08:00（索引 48）预置一条记录，删除它会写删除墓碑。
Future<(TimeProvider, _FailingSlotWriteStore)> _createProvider({
  Duration localSaveDebounce = const Duration(hours: 1),
}) async {
  _installPluginMocks();
  final values = <String, Object>{
    'on_this_day_last_shown_date': OnThisDayService.dateKeyOf(DateTime.now()),
    'daily_slots': jsonEncode({
      _dateKey(DateTime.now()): [
        {'i': 48, 'l': '写盘测试', 'c': 4280391411, 'ts': 1},
      ],
    }),
  };
  SharedPreferences.setMockInitialValues(values);
  final store = _FailingSlotWriteStore({
    for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
  });
  SharedPreferencesStorePlatform.instance = store;

  final provider = TimeProvider(
    identityModePlatformOverride: false,
    googleCalendarSyncPlatformOverride: false,
    localSaveDebounce: localSaveDebounce,
    scheduleSyncDependencies: _offlineDependencies(),
  );
  await _waitLoaded(provider);
  return (provider, store);
}

Future<String?> _readSlots() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs.getString('daily_slots');
}

Future<void> _pumpMainScreen(WidgetTester tester, TimeProvider provider) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<TimeProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => MainTabProvider()),
        ChangeNotifierProvider(create: (_) => DesktopShortcutProvider()),
        ChangeNotifierProvider(create: (_) => DesktopLayoutProvider()),
        ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
        ChangeNotifierProvider(create: (_) => BackgroundImageProvider()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const MainScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final throws in [false, true]) {
    test('出行删除写盘${throws ? '抛异常' : '返回 false'}后同步读取原文档', () async {
      final original = TravelRecordsDocument(records: [
        TravelRecord(date: DateTime(2026, 10, 1), location: '杭州', event: '散步'),
      ]);
      final originalText = original.toMarkdown();
      SharedPreferences.setMockInitialValues({
        'travel_records_draft': originalText,
      });
      final store = _FailingWritesStore({
        'flutter.travel_records_draft': originalText,
      })..throwOnWrite = throws;
      SharedPreferencesStorePlatform.instance = store;

      final deleted = original.deleteByDate(DateTime(2026, 10, 1));
      expect(await TravelLocalStore.saveDraft(deleted.toMarkdown()), isFalse);
      final readBack = TravelRecordsDocument.fromMarkdown(
        (await TravelLocalStore.loadDraft())!,
      );
      expect(readBack.records.single.location, '杭州');
      expect(readBack.deletedDateKeys, isEmpty);
    });
  }

  test('首次保存出行记录失败后不留下缓存草稿', () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = _FailingWritesStore({});
    expect(await TravelLocalStore.saveDraft('未落盘'), isFalse);
    expect(await TravelLocalStore.loadDraft(), isNull);
  });

  test('出行失败回滚不会覆盖排队中的新保存', () async {
    SharedPreferences.setMockInitialValues({'travel_records_draft': '旧记录'});
    final store = _DelayedTravelFailureStore({
      'flutter.travel_records_draft': '旧记录',
    });
    SharedPreferencesStorePlatform.instance = store;
    expect(await TravelLocalStore.loadDraft(), '旧记录');

    final failed = TravelLocalStore.saveDraft('失败的删除');
    await store.started.future;
    final next = TravelLocalStore.saveDraft('新记录');
    final read = TravelLocalStore.loadDraft();
    store.release.complete();

    expect(await failed, isFalse);
    expect(await next, isTrue);
    expect(await read, '新记录');
  });

  test('写盘返回 false：置位保存失败，重试成功后墓碑真正落盘', () async {
    final (provider, store) = await _createProvider();
    addTearDown(provider.dispose);
    expect(provider.hasLocalSaveFailure, isFalse);

    store.failSlotWrites = true;
    provider.removeEventFromSlot(48);
    expect(await provider.retryLocalSave(), isFalse);

    expect(store.slotWriteAttempts, greaterThan(0));
    expect(store.slotWritesPersisted, 0);
    expect(provider.hasLocalSaveFailure, isTrue);
    expect(provider.localSaveFailureMessage, isNotNull);
    // 失败期间不能假装写入成功
    expect(await _readSlots(), isNot(contains('"del":true')));

    store.failSlotWrites = false;
    expect(await provider.retryLocalSave(), isTrue);

    expect(provider.hasLocalSaveFailure, isFalse);
    expect(provider.localSaveFailureMessage, isNull);
    expect(store.slotWritesPersisted, greaterThan(0));
    expect(await _readSlots(), contains('"del":true'));
  });

  test('写盘抛异常：异常被吞掉、置位保存失败，恢复后重试成功', () async {
    final (provider, store) = await _createProvider();
    addTearDown(provider.dispose);

    store.throwOnSlotWrite = true;
    provider.removeEventFromSlot(48);
    // 不应把异常抛给调用方
    expect(await provider.retryLocalSave(), isFalse);

    expect(store.slotWriteAttempts, greaterThan(0));
    expect(provider.hasLocalSaveFailure, isTrue);

    store.throwOnSlotWrite = false;
    expect(await provider.retryLocalSave(), isTrue);
    expect(provider.hasLocalSaveFailure, isFalse);
    expect(await _readSlots(), contains('"del":true'));
  });

  test('正常写盘不会误报保存失败', () async {
    final (provider, store) = await _createProvider();
    addTearDown(provider.dispose);

    provider.removeEventFromSlot(48);
    expect(await provider.retryLocalSave(), isTrue);

    expect(store.slotWriteAttempts, 1);
    expect(store.slotWritesPersisted, 1);
    expect(provider.hasLocalSaveFailure, isFalse);
  });

  test('普通编辑触发的防抖保存失败同样会置位', () async {
    // 线上没有「重试保存」按钮可点的时候，就是这条路径：编辑 → 防抖 → 写盘失败
    final (provider, store) = await _createProvider(
      localSaveDebounce: const Duration(milliseconds: 20),
    );
    addTearDown(provider.dispose);

    store.failSlotWrites = true;
    provider.removeEventFromSlot(48);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!provider.hasLocalSaveFailure &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(provider.hasLocalSaveFailure, isTrue);
    expect(store.slotWriteAttempts, greaterThan(0));
  });

  test('出行 / 打卡 / 日记的本地写入失败会返回 false', () async {
    SharedPreferences.setMockInitialValues(const {});
    final store = _FailingWritesStore(const {});
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferences.setMockInitialValues(const {}));

    expect(await TravelLocalStore.saveDraft('出行记录'), isFalse);
    expect(await CheckInLocalStore.saveDraft(CheckInDocument.empty), isFalse);
    expect(
      await DiaryLocalStore.saveDraftBody(
        DiaryKind.g,
        DateTime(2026, 10, 28),
        '正文',
      ),
      isFalse,
    );
    expect(
      await DiaryLocalStore.saveDraftStartedAt(
        DiaryKind.g,
        DateTime(2026, 10, 28),
        DateTime(2026, 10, 28, 9),
      ),
      isFalse,
    );

    // 平台通道抛异常时同样按失败返回，不能让异常冒到 UI 层
    store.throwOnWrite = true;
    expect(await TravelLocalStore.saveDraft('出行记录'), isFalse);
    expect(await CheckInLocalStore.saveDraft(CheckInDocument.empty), isFalse);
    expect(
      await DiaryLocalStore.saveDraftBody(
        DiaryKind.g,
        DateTime(2026, 10, 28),
        '正文',
      ),
      isFalse,
    );
  });

  test('打卡目标本地保存失败时返回失败结果，不报告同步成功', () async {
    _installPluginMocks();
    AppIdentityService.resetForTesting();
    addTearDown(AppIdentityService.resetForTesting);
    addTearDown(() => SharedPreferences.setMockInitialValues(const {}));

    final values = <String, Object>{
      AppIdentityService.modeKey: 'manual',
      AppIdentityService.legacyScheduleUserKey: DiaryKind.g.code,
    };
    SharedPreferences.setMockInitialValues(values);
    SharedPreferencesStorePlatform.instance = _FailingWritesStore({
      for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
    });

    final service = CheckInSyncService(tokenLoader: () async => null);
    await service.initialize(silent: true);
    final result = await service.saveGoal(
      CheckInGoal(
        id: 'goal-1',
        ownerId: '',
        ownerEmail: '',
        name: '运动',
        description: '',
        color: const Color(0xFF000000),
        icon: Icons.flag,
        period: CheckInPeriod.daily,
        targetCount: 1,
        requirePhoto: false,
        requireLocation: false,
      ),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('本地保存失败'));
    expect(service.goalsWithRecords, isEmpty);
    expect(await CheckInLocalStore.loadDraft(), isNull);
  });

  for (final throws in [false, true]) {
    test('打卡写盘${throws ? '抛异常' : '返回 false'}后重试不留下重复记录', () async {
      final goal = CheckInGoal(
        id: 'goal-1',
        ownerId: 'manual-g',
        ownerEmail: KnownGoogleUsers.guaiGuaiEmail,
        name: '运动',
        description: '',
        color: const Color(0xFF000000),
        icon: Icons.flag,
        period: CheckInPeriod.daily,
        targetCount: 1,
        requirePhoto: false,
        requireLocation: false,
      );
      final original = CheckInDocument(goals: [goal], records: []);
      final values = <String, Object>{
        AppIdentityService.modeKey: 'manual',
        AppIdentityService.legacyScheduleUserKey: DiaryKind.g.code,
        'check_in_data_draft': original.toMarkdown(),
      };
      SharedPreferences.setMockInitialValues(values);
      SharedPreferencesStorePlatform.instance = _FailingWritesStore({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      })..throwOnWrite = throws;

      final service = CheckInSyncService(tokenLoader: () async => null);
      await service.initialize(silent: true);
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await service.submitCheckIn(goal: goal);
        expect(result.success, isFalse);
        expect(result.error, contains('本地保存失败'));
        expect(service.document.records, isEmpty);
        expect((await CheckInLocalStore.loadDraft())!.records, isEmpty);
      }
    });
  }

  testWidgets('真实写盘失败时壳层显示横幅，恢复后重试自动消失', (tester) async {
    late TimeProvider provider;
    late _FailingSlotWriteStore store;
    await tester.runAsync(() async {
      (provider, store) = await _createProvider();
      store.failSlotWrites = true;
      provider.removeEventFromSlot(48);
      expect(await provider.retryLocalSave(), isFalse);
    });
    expect(provider.hasLocalSaveFailure, isTrue);

    await _pumpMainScreen(tester, provider);
    expect(find.byType(DataFailureBanner), findsOneWidget);
    expect(find.text('本地保存失败，最近的修改可能丢失'), findsOneWidget);
    expect(find.text('重试保存'), findsOneWidget);

    await tester.runAsync(() async {
      store.failSlotWrites = false;
      expect(await provider.retryLocalSave(), isTrue);
    });
    await tester.pump();

    expect(provider.hasLocalSaveFailure, isFalse);
    expect(find.byType(DataFailureBanner), findsNothing);
  });
}
