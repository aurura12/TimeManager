import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/screens/diary_conflict_screen.dart';
import 'package:time_manager/screens/diary_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/diary_local_store.dart';
import 'package:time_manager/services/diary_auto_sync_service.dart';
import 'package:time_manager/services/diary_sync_service.dart';
import 'package:time_manager/services/sync_status_coordinator.dart';
import 'package:time_manager/theme/app_theme.dart';

class _ConflictAutoSync extends DiaryAutoSyncService {
  _ConflictAutoSync()
      : super(
          pendingChecker: () async => true,
          syncRunner: () async =>
              const SyncOperationResult.conflict('远端已更新', conflictCount: 1),
        );

  int flushes = 0;

  @override
  Future<SyncOperationResult?> flush({SyncStatusCoordinator? coordinator}) {
    flushes++;
    return Future.value(
      const SyncOperationResult.conflict('远端已更新', conflictCount: 1),
    );
  }
}

class _RecordingSyncService extends DiarySyncService {
  String? path;
  String? body;
  String? expectedRemoteSha;
  int calls = 0;
  SyncOperationResult result =
      const SyncOperationResult.success(message: '已用本地内容覆盖远端');

  @override
  Future<SyncOperationResult> overwriteRemote({
    required DiaryKind kind,
    required DateTime date,
    String? path,
    String? body,
    String? expectedRemoteSha,
  }) async {
    calls++;
    this.path = path;
    this.body = body;
    this.expectedRemoteSha = expectedRemoteSha;
    return result;
  }
}

String _dateLabel(DateTime date) => DateFormat('yyyy年M月d日').format(date);

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 120,
}) async {
  for (var i = 0; i < maxPumps && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsWidgets);
}

Future<void> _seedConflict(
  DateTime date,
  String localBody, {
  bool withBaseline = true,
}) async {
  await DiaryLocalStore.saveDraftBody(DiaryKind.g, date, localBody);
  await DiaryLocalStore.saveDraftStartedAt(
    DiaryKind.g,
    date,
    DateTime(date.year, date.month, date.day, 8),
  );
  await DiaryLocalStore.markDraftPending(DiaryKind.g, date);
  if (!withBaseline) return;
  // 旧基线：远端后来被别人改了，sha 与本地记录不一致。
  await DiaryLocalStore.saveRemoteBaseline(
    DiaryKind.g,
    date,
    path: 'G${_dateLabel(date)}.md',
    sha: 'old-sha',
    notFound: false,
  );
}

Future<void> _pumpDiary(
  WidgetTester tester, {
  required DateTime date,
  required String localBody,
  DiarySyncService? syncService,
  bool withBaseline = true,
}) async {
  SharedPreferences.setMockInitialValues({
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'g',
  });
  AppIdentityService.resetForTesting();
  await _seedConflict(date, localBody, withBaseline: withBaseline);

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => call.method == 'read' ? 'fake-token' : null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_diary_conflict_flow_test',
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: DiaryScreen(syncService: syncService),
    ),
  );
  await _pumpUntil(tester, find.byIcon(Icons.chevron_left));
  await _pumpUntil(tester, find.text('处理冲突'));
}


/// 冲突处理期间底层的同步状态灯会持续转圈，不能用 pumpAndSettle。
Future<void> _advance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

MockClient _client(DateTime date, String remoteBody) {
  return MockClient((request) async {
    if (request.url.path.contains('/git/trees/')) {
      return http.Response(
        jsonEncode({
          'tree': [
            {
              'path': 'G${_dateLabel(date)}.md',
              'type': 'blob',
              'sha': 'remote-sha',
            },
          ],
          'truncated': false,
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response(
      jsonEncode({
        'sha': 'remote-sha',
        'content': base64Encode(utf8.encode(remoteBody)),
      }),
      200,
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  testWidgets('冲突时出现处理入口，并能打开逐块对比页', (tester) async {
    final today = DateTime.now();
    final date = DateTime(today.year, today.month, today.day);

    await http.runWithClient(
      () async {
        await _pumpDiary(
          tester,
          date: date,
          localBody: '本地新写的段落',
        );
        expect(find.text('远端已被其他设备更新'), findsOneWidget);

        await tester.tap(find.text('处理冲突'));
        await _advance(tester);

        expect(find.byType(DiaryConflictScreen), findsOneWidget);
        expect(find.text('用远端覆盖本地'), findsOneWidget);
        expect(find.text('合并并上传'), findsOneWidget);
      },
      () => _client(date, '远端被别人改成的段落'),
    );
  });

  testWidgets('选择用本地覆盖远端时把当前正文交给服务', (tester) async {
    final today = DateTime.now();
    final date = DateTime(today.year, today.month, today.day);
    final service = _RecordingSyncService();

    await http.runWithClient(
      () async {
        await _pumpDiary(
          tester,
          date: date,
          localBody: '本地新写的段落',
          syncService: service,
        );

        await tester.tap(find.text('处理冲突'));
        await _advance(tester);
        await tester.tap(find.text('用本地覆盖远端'));
        await _advance(tester);
        await tester.tap(find.text('用本地覆盖'));
        await _advance(tester);

        expect(service.calls, 1);
        expect(service.path, 'G${_dateLabel(date)}.md');
        expect(service.body, contains('本地新写的段落'));
        expect(service.expectedRemoteSha, isNull);
      },
      () => _client(date, '远端被别人改成的段落'),
    );
  });

  testWidgets('选择用远端覆盖本地时编辑器换成远端正文', (tester) async {
    final today = DateTime.now();
    final date = DateTime(today.year, today.month, today.day);

    await http.runWithClient(
      () async {
        await _pumpDiary(
          tester,
          date: date,
          localBody: '本地新写的段落',
        );

        await tester.tap(find.text('处理冲突'));
        await _advance(tester);
        await tester.tap(find.text('用远端覆盖本地'));
        await _advance(tester);
        await tester.tap(find.text('用远端覆盖'));
        await _advance(tester);

        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          contains('远端被别人改成的段落'),
        );
        expect(find.text('处理冲突'), findsNothing);
      },
      () => _client(date, '远端被别人改成的段落'),
    );
  });

  testWidgets('没有远端基线但有本地草稿时也要给出冲突入口', (tester) async {
    final today = DateTime.now();
    final date = DateTime(today.year, today.month, today.day);

    await http.runWithClient(
      () async {
        await _pumpDiary(
          tester,
          date: date,
          localBody: '本地新写的段落',
          withBaseline: false,
        );

        // 自动上传对这一天同样只能报冲突（没有基线不敢覆盖远端），
        // 页面必须给出入口，否则草稿永远传不上去。
        expect(find.text('处理冲突'), findsOneWidget);
      },
      () => _client(date, '远端被别人改成的段落'),
    );
  });

  testWidgets('批量同步报告冲突时不会把冲突错标到当前日期', (tester) async {
    final today = DateTime.now();
    final date = DateTime(today.year, today.month, today.day);
    final autoSync = _ConflictAutoSync();

    await http.runWithClient(
      () async {
        // 基线指向远端当前版本：这一天确实没有冲突，只是还有待上传的修改。
        SharedPreferences.setMockInitialValues({
          AppIdentityService.modeKey: 'manual',
          AppIdentityService.legacyScheduleUserKey: 'g',
        });
        AppIdentityService.resetForTesting();
        await DiaryLocalStore.saveDraftBody(DiaryKind.g, date, '本地正文');
        await DiaryLocalStore.markDraftPending(DiaryKind.g, date);
        await DiaryLocalStore.saveRemoteBaseline(
          DiaryKind.g,
          date,
          path: 'G${_dateLabel(date)}.md',
          sha: 'remote-sha',
          notFound: false,
        );

        final messenger = TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'read' ? 'fake-token' : null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp/time_manager_diary_conflict_flow_test',
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('home_widget'),
          (call) async => null,
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: DiaryScreen(autoSyncService: autoSync),
          ),
        );
        await _pumpUntil(tester, find.byIcon(Icons.chevron_left));

        await tester.enterText(find.byType(TextField), '又写了一点');
        await tester.pump(const Duration(seconds: 4));
        await _advance(tester);

        expect(autoSync.flushes, greaterThanOrEqualTo(1));
        expect(find.text('处理冲突'), findsNothing);
        expect(find.text('远端已被其他设备更新'), findsNothing);
      },
      () => _client(date, '远端被别人改成的段落'),
    );
  });
}
