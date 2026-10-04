import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/add_target_screen.dart';
import 'package:time_manager/screens/target_detail_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/schedule_gitee_service.dart';
import 'package:time_manager/services/schedule_sync_dependencies.dart';
import 'package:time_manager/services/target_sync_dependencies.dart';

ScheduleSyncDependencies _offlineScheduleDependencies() {
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

Target _makeTarget({
  String id = 'target-1',
  String name = '初始目标',
  Color color = const Color(0xFF9CB86A),
  String period = '每天',
  double durationHours = 1,
}) {
  return Target(
    id: id,
    name: name,
    type: TargetType.duration,
    color: color,
    period: period,
    durationHours: durationHours,
  );
}

Future<TimeProvider> _createProvider(
  WidgetTester tester, {
  required bool saveSucceeds,
  Target? initialTarget,
}) async {
  final preferences = <String, Object>{
    AppIdentityService.modeKey: 'manual',
    AppIdentityService.legacyScheduleUserKey: 'j',
  };
  if (initialTarget != null) {
    preferences['identity_j_targets'] = [json.encode(initialTarget.toJson())];
  }
  SharedPreferences.setMockInitialValues(preferences);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  final provider = TimeProvider(
    identityModePlatformOverride: true,
    // This test does not exercise remote target syncing. Keep the debounce
    // pending instead of creating a zero-delay timer that outlives the test.
    scheduleGiteeDebounce: const Duration(days: 1),
    scheduleSyncDependencies: _offlineScheduleDependencies(),
    targetSyncDependencies: TargetSyncDependencies.disabled(),
    saveDataOverride: () async => saveSucceeds,
  );
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        !provider.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  expect(provider.isInitialLoadFinished, isTrue);
  return provider;
}

Color? _detailIconBackground(WidgetTester tester) {
  final icon = find.byIcon(Icons.timer_outlined);
  expect(icon, findsOneWidget);
  final container =
      find.ancestor(of: icon, matching: find.byType(Container)).first;
  final decoration = tester.widget<Container>(container).decoration;
  return decoration is BoxDecoration ? decoration.color : null;
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

  testWidgets('目标详情实时刷新名称、颜色、周期和目标值', (tester) async {
    final initial = _makeTarget();
    final provider = await _createProvider(
      tester,
      saveSucceeds: true,
      initialTarget: initial,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          home: TargetDetailScreen(targetId: initial.id),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('初始目标'), findsWidgets);
    expect(find.text('每天'), findsOneWidget);
    expect(find.text('超过 1.0小时'), findsOneWidget);
    final oldIconBackground = _detailIconBackground(tester);

    final updated = initial.copyWith(
      name: '更新后的目标',
      color: const Color(0xFF7B1FA2),
      period: '每周',
      durationHours: 3,
    );
    expect(await provider.updateTarget(updated), isTrue);
    await tester.pump();

    expect(find.text('更新后的目标'), findsWidgets);
    expect(find.text('每周'), findsOneWidget);
    expect(find.text('超过 3.0小时'), findsOneWidget);
    expect(provider.targetById(initial.id)?.color, updated.color);
    expect(_detailIconBackground(tester), isNot(oldIconBackground));
    provider.dispose();
  });

  for (final input in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('目标日历支持 $input 左右拖动', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(
        input == PointerDeviceKind.mouse ? 900 : 360,
        900,
      );
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final target = _makeTarget();
      final provider = await _createProvider(
        tester,
        saveSucceeds: true,
        initialTarget: target,
      );
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: TargetDetailScreen(targetId: target.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('日历'));
      await tester.pumpAndSettle();

      final calendarCard = find.ancestor(
        of: find.text('日历'),
        matching: find.byType(Card),
      );
      final calendar = find.descendant(
        of: calendarCard,
        matching: find.byType(SingleChildScrollView),
      );
      final controller =
          tester.widget<SingleChildScrollView>(calendar).controller!;
      final vertical = tester
          .state<ScrollableState>(
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .first,
          )
          .position;
      expect(controller.position.maxScrollExtent, greaterThan(0));

      for (final direction in [1.0, -1.0]) {
        controller.jumpTo(controller.position.maxScrollExtent / 2);
        await tester.pump();
        final before = controller.offset;
        final verticalBefore = vertical.pixels;
        final gesture = await tester.startGesture(
          tester.getCenter(calendar),
          kind: input,
        );
        await gesture.moveBy(Offset(direction * 40, 0));
        await tester.pump();
        await gesture.moveBy(Offset(direction * 40, 0));
        await tester.pump();

        expect(
          controller.offset,
          direction > 0 ? lessThan(before) : greaterThan(before),
        );
        expect(vertical.pixels, verticalBefore);
        await gesture.up();
        await tester.pumpAndSettle();
      }

      if (input == PointerDeviceKind.touch) {
        final before = vertical.pixels;
        await tester.drag(calendar, const Offset(0, 100));
        await tester.pumpAndSettle();
        expect(vertical.pixels, lessThan(before));
      }
      expect(tester.takeException(), isNull);
    },
        variant: TargetPlatformVariant.only(input == PointerDeviceKind.mouse
            ? TargetPlatform.macOS
            : TargetPlatform.android));
  }

  testWidgets('目标保存失败时编辑页保留并提示', (tester) async {
    final initial = _makeTarget();
    final provider = await _createProvider(
      tester,
      saveSucceeds: false,
      initialTarget: initial,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          home: AddTargetScreen(target: initial),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(AddTargetScreen), findsOneWidget);
    expect(find.text('保存失败，请稍后重试'), findsOneWidget);
    expect(provider.targetById(initial.id)?.name, initial.name);
    provider.dispose();
  });

  testWidgets('目标被删除后详情页安全返回', (tester) async {
    final target = _makeTarget();
    final provider = await _createProvider(
      tester,
      saveSucceeds: true,
      initialTarget: target,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TargetDetailScreen(targetId: target.id),
                    ),
                  );
                },
                child: const Text('打开目标'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开目标'));
    await tester.pumpAndSettle();
    expect(find.byType(TargetDetailScreen), findsOneWidget);

    provider.deleteTarget(target);
    await tester.pumpAndSettle();

    expect(find.byType(TargetDetailScreen), findsNothing);
    expect(find.text('打开目标'), findsOneWidget);
    provider.dispose();
  });

  testWidgets('详情页手动删除不会误关闭搜索结果上一层', (tester) async {
    final target = _makeTarget();
    final provider = await _createProvider(
      tester,
      saveSucceeds: true,
      initialTarget: target,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TargetDetailScreen(targetId: target.id),
                    ),
                  );
                },
                child: const Text('搜索结果页'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('搜索结果页'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byType(TargetDetailScreen), findsNothing);
    expect(find.text('搜索结果页'), findsOneWidget);
    provider.dispose();
  });
}
