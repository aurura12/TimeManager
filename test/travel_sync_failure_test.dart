import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/models/travel_record.dart';
import 'package:time_manager/screens/travel_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/sync_status_coordinator.dart';
import 'package:time_manager/services/travel_local_store.dart';
import 'package:time_manager/theme/app_theme.dart';

class _TravelWriteStore extends InMemorySharedPreferencesStore {
  _TravelWriteStore() : super.withData({});

  bool failAll = false;
  final Set<int> failAttempts = {};
  int attempts = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('travel_records_draft')) {
      attempts++;
      if (failAll || failAttempts.contains(attempts)) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

Future<void> _pumpTravel(
  WidgetTester tester,
  SyncStatusCoordinator coordinator,
) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<SyncStatusCoordinator>.value(
      value: coordinator,
      child: MaterialApp(theme: AppTheme.light(), home: const TravelScreen()),
    ),
  );
  await _pumpUntil(
      tester, () => find.byTooltip('拉取出行记录').evaluate().isNotEmpty);
}

Future<void> _addRecord(WidgetTester tester) async {
  await tester.tap(find.text('新增记录'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, '杭州');
  await tester.enterText(find.byType(TextField).last, '散步');
  await tester.tap(find.text('保存'));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppIdentityService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'read' ? 'fake-token' : null,
    );
  });
  tearDown(AppIdentityService.resetForTesting);

  testWidgets('拉取后本地保存失败时回滚页面并上报失败', (tester) async {
    final store = _TravelWriteStore()..failAll = true;
    SharedPreferencesStorePlatform.instance = store;
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(coordinator.dispose);
    final remote = TravelRecordsDocument(records: [
      TravelRecord(date: DateTime.now(), location: '杭州', event: '散步'),
    ]).toMarkdown();

    await http.runWithClient(() async {
      await _pumpTravel(tester, coordinator);
      await _pumpUntil(
          tester,
          () =>
              coordinator.stateFor(SyncModule.travel).status ==
              SyncModuleStatus.failed);
      expect(find.text('还没有出行记录'), findsOneWidget);
      expect(await TravelLocalStore.loadDraft(), isNull);
      expect(
          coordinator.stateFor(SyncModule.travel).message, contains('本地保存失败'));

      store.failAll = false;
      await tester.tap(find.byTooltip('拉取出行记录'));
      await _pumpUntil(
          tester,
          () =>
              coordinator.stateFor(SyncModule.travel).status ==
              SyncModuleStatus.success);
      await tester.pump();
      expect(find.text('杭州'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
        () => MockClient((_) async => http.Response(
              jsonEncode({
                'sha': 'remote-sha',
                'content': base64Encode(utf8.encode(remote))
              }),
              200,
            )));
  });

  for (final failAttempt in [2, 3]) {
    testWidgets('出行推送第 $failAttempt 次本地保存失败时不报告成功', (tester) async {
      final store = _TravelWriteStore()..failAttempts.add(failAttempt);
      SharedPreferencesStorePlatform.instance = store;
      final coordinator = SyncStatusCoordinator(
        store: InMemorySyncStatusStore(),
        loadIdentityBeforeState: false,
      );
      addTearDown(coordinator.dispose);
      var reads = 0;
      var writes = 0;

      await http.runWithClient(() async {
        await _pumpTravel(tester, coordinator);
        await _pumpUntil(
          tester,
          () =>
              reads == 1 &&
              tester
                      .widget<IconButton>(find.widgetWithIcon(
                          IconButton, Icons.download_outlined))
                      .onPressed != null,
        );
        await _addRecord(tester);
        await _pumpUntil(
            tester,
            () =>
                coordinator.stateFor(SyncModule.travel).status ==
                SyncModuleStatus.failed);
        final state = coordinator.stateFor(SyncModule.travel);
        expect(state.message, contains('本地保存失败'));
        expect(writes, failAttempt == 2 ? 0 : 1);
        if (failAttempt == 2) {
          expect(reads, 1, reason: '推送前保存失败时不应读取或修改远端');
        } else {
          expect(state.message, contains('远端已同步'));
        }
        expect(find.text('同步成功'), findsNothing);
        expect(tester.takeException(), isNull);
      },
          () => MockClient((request) async {
                if (request.method == 'GET') {
                  reads++;
                  return http.Response('', 404);
                }
                writes++;
                return http.Response(
                    jsonEncode({
                      'content': {'sha': 'new-sha'}
                    }),
                    201);
              }));
    });
  }

  testWidgets('已与远端一致时，本地保存失败仍上报失败', (tester) async {
    final store = _TravelWriteStore()..failAttempts.add(3);
    SharedPreferencesStorePlatform.instance = store;
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(coordinator.dispose);
    var reads = 0;
    var writes = 0;

    await http.runWithClient(() async {
      await _pumpTravel(tester, coordinator);
      await _pumpUntil(
        tester,
        () =>
            reads == 1 &&
            tester
                    .widget<IconButton>(find.widgetWithIcon(
                        IconButton, Icons.download_outlined))
                    .onPressed != null,
      );
      await _addRecord(tester);
      await _pumpUntil(
          tester,
          () =>
              coordinator.stateFor(SyncModule.travel).status ==
              SyncModuleStatus.failed);
      expect(coordinator.stateFor(SyncModule.travel).message, contains('远端一致'));
      expect(
          coordinator.stateFor(SyncModule.travel).message, contains('本地保存失败'));
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              if (request.method != 'GET') {
                writes++;
                return http.Response('', 500);
              }
              reads++;
              if (reads == 1) return http.Response('', 404);
              final local = (await TravelLocalStore.loadDraft())!;
              return http.Response(
                jsonEncode({
                  'sha': 'remote-sha',
                  'content': base64Encode(utf8.encode(local)),
                }),
                200,
              );
            }));
  });
}
