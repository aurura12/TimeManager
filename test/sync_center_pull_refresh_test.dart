import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/check_in_document.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/known_google_users.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/models/travel_record.dart';
import 'package:time_manager/screens/travel_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/check_in_local_store.dart';
import 'package:time_manager/services/check_in_sync_service.dart';
import 'package:time_manager/services/sync_center_service.dart';
import 'package:time_manager/services/travel_local_store.dart';
import 'package:time_manager/theme/app_theme.dart';

/// 「同步中心 → 拉取远端」写在本地存储上、跑在同步中心自己的服务实例里；
/// 页面持有的内存副本必须跟着刷新，否则界面继续显示旧数据，改动后的推送
/// 还会被判成内容冲突而中止。
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

SyncCenterController _controllerWithTravelPull(
  Future<void> Function() pull,
) {
  return SyncCenterController(
    operations: SyncCenterOperations(
      operations: {
        for (final module in SyncModule.values)
          module: () async => const SyncOperationResult.success(),
      },
      pulls: {
        SyncModule.travel: () async {
          await pull();
          return const SyncOperationResult.success(message: '出行记录已按远端更新');
        },
      },
    ),
    store: InMemorySyncStatusStore(),
    loadIdentityBeforeState: false,
  );
}

CheckInGoal _goal(String name) {
  return CheckInGoal(
    id: '1700000000000',
    ownerId: '',
    ownerEmail: KnownGoogleUsers.guaiGuaiEmail,
    name: name,
    description: '',
    color: const Color(0xFF4CAF50),
    icon: const IconData(0xe000),
    period: CheckInPeriod.daily,
    targetCount: 1,
    updatedAt: 1,
  );
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

  test('拉取远端结束后广播模块，没有拉取入口的模块不广播', () async {
    final controller = _controllerWithTravelPull(() async {});
    addTearDown(controller.dispose);
    final emitted = <SyncModule>[];
    final subscription = controller.pullCompleted.listen(emitted.add);
    addTearDown(subscription.cancel);

    await controller.pull(SyncModule.travel);
    // 打卡没有配置拉取入口，控制器不应发信号。
    await controller.pull(SyncModule.checkIn);
    await Future<void>.delayed(Duration.zero);

    expect(emitted, [SyncModule.travel]);
  });

  testWidgets('同步中心拉取远端后，出行页立刻显示拉回来的记录', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final remoteDocument = TravelRecordsDocument(records: [
      TravelRecord(date: DateTime.now(), location: '杭州', event: '散步'),
    ]);
    final controller = _controllerWithTravelPull(() async {
      // 同步中心的拉取只写本地存储（远端的合并结果），不碰页面内存。
      await TravelLocalStore.saveDraft(remoteDocument.toMarkdown());
    });
    addTearDown(controller.dispose);
    final coordinator = SyncStatusCoordinator(
      store: InMemorySyncStatusStore(),
      loadIdentityBeforeState: false,
    );
    addTearDown(coordinator.dispose);

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SyncStatusCoordinator>.value(
              value: coordinator,
            ),
            ChangeNotifierProvider<SyncCenterController>.value(
              value: controller,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const TravelScreen(),
          ),
        ),
      );
      // 进页面自动拉取一次，远端此时没有记录。
      await _pumpUntil(tester, () => find.text('还没有出行记录').evaluate().isNotEmpty);

      await controller.pull(SyncModule.travel);
      await _pumpUntil(tester, () => find.text('杭州').evaluate().isNotEmpty);

      expect(find.text('还没有出行记录'), findsNothing);
      expect(tester.takeException(), isNull);
    }, () => MockClient((_) async => http.Response('', 404)));
  });

  test('打卡服务能重读同步中心刚写进本地存储的数据', () async {
    // 没有 token 时 initialize 不会访问网络，只读本地存储。
    final service = CheckInSyncService(tokenLoader: () async => null);
    await service.initialize(silent: true, retryPhotoCleanup: false);
    expect(service.goalsWithRecords, isEmpty);

    await CheckInLocalStore.saveDraft(
      CheckInDocument(goals: [_goal('读书')], records: const []),
    );
    await service.reloadLocal();

    expect(service.goalsWithRecords.single.name, '读书');
  });
}
