import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/screens/diary_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/diary_auto_sync_service.dart';
import 'package:time_manager/services/sync_status_coordinator.dart';
import 'package:time_manager/theme/app_theme.dart';

/// 只记录触发次数，不真正访问远端。
class _RecordingAutoSync extends DiaryAutoSyncService {
  _RecordingAutoSync()
      : super(
          pendingChecker: () async => false,
          syncRunner: () async => const SyncOperationResult.success(),
        );

  int flushes = 0;

  @override
  Future<SyncOperationResult?> flush({SyncStatusCoordinator? coordinator}) {
    flushes++;
    return Future.value(const SyncOperationResult.success());
  }
}

class _RecordingAutoSyncFactory {
  final List<_RecordingAutoSync> created = [];

  _RecordingAutoSync build() {
    final service = _RecordingAutoSync();
    created.add(service);
    return service;
  }

  _RecordingAutoSync get latest => created.last;
}

void _installPluginMocks() {
  SharedPreferences.setMockInitialValues({});
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_diary_auto_push_test',
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 60,
}) async {
  for (var i = 0; i < maxPumps && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pumpDiary(
  WidgetTester tester,
  _RecordingAutoSyncFactory factory,
) async {
  _installPluginMocks();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: DiaryScreen(autoSyncService: factory.build()),
    ),
  );
  await _pumpUntil(tester, find.byIcon(Icons.chevron_left));
  expect(find.byIcon(Icons.chevron_left), findsOneWidget);
}

void main() {
  setUp(AppIdentityService.resetForTesting);
  tearDown(() {
    AppIdentityService.resetForTesting();
    DiaryAutoSyncService.resetForTesting();
  });

  testWidgets('停止输入 3 秒后自动上传一次', (tester) async {
    final factory = _RecordingAutoSyncFactory();
    await _pumpDiary(tester, factory);

    await tester.enterText(find.byType(TextField), '今天写了点东西');
    await tester.pump(const Duration(milliseconds: 400));
    expect(factory.latest.flushes, 0);

    await tester.pump(const Duration(seconds: 3));
    expect(factory.latest.flushes, 1);
  });

  testWidgets('切换日期前立即补推一次', (tester) async {
    final factory = _RecordingAutoSyncFactory();
    await _pumpDiary(tester, factory);

    await tester.enterText(find.byType(TextField), '还没等到 3 秒就切日');
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();

    expect(factory.latest.flushes, 1);
  });

  testWidgets('切到后台立即补推一次', (tester) async {
    final factory = _RecordingAutoSyncFactory();
    await _pumpDiary(tester, factory);

    await tester.enterText(find.byType(TextField), '后台补推');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(factory.latest.flushes, 1);
  });

  testWidgets('离开日记页时补推一次', (tester) async {
    final factory = _RecordingAutoSyncFactory();
    await _pumpDiary(tester, factory);

    await tester.enterText(find.byType(TextField), '离开页面也要上传');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(factory.latest.flushes, 1);
  });
}
