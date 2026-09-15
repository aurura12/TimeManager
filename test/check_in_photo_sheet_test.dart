import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/services/check_in_location_service.dart';
import 'package:time_manager/services/check_in_sync_service.dart';
import 'package:time_manager/widgets/check_in_photo_sheet.dart';

CheckInGoal _goal({bool requireLocation = false}) {
  return CheckInGoal(
    id: 'goal-1',
    ownerId: 'owner-1',
    ownerEmail: 'owner@example.com',
    name: '阅读',
    description: '',
    color: Colors.blue,
    icon: Icons.menu_book,
    period: CheckInPeriod.daily,
    targetCount: 1,
    requirePhoto: false,
    requireLocation: requireLocation,
  );
}

Widget _app({required CheckInGoal goal}) {
  return MaterialApp(
    home: Scaffold(
      body: CheckInPhotoSheet(
        goal: goal,
        syncService: CheckInSyncService(),
      ),
    ),
  );
}

void main() {
  tearDown(() {
    CheckInLocationService.settingsLauncherForTesting = null;
    CheckInLocationService.locationLoaderForTesting = null;
  });

  testWidgets('窄屏大字体下弹窗内容可滚动且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
        child: _app(goal: _goal()),
      ),
    );
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('永久拒绝定位时可以通过恢复入口打开系统设置', (tester) async {
    var launchCount = 0;
    CheckInLocationService.locationLoaderForTesting = () async {
      return const CheckInLocationAccessResult(
        permissionStatus: CheckInLocationPermissionStatus.deniedForever,
      );
    };
    CheckInLocationService.settingsLauncherForTesting = () async {
      launchCount++;
      return true;
    };

    await tester.pumpWidget(_app(goal: _goal(requireLocation: true)));
    await tester.pump();

    expect(find.text('定位权限已拒绝，请在系统设置中开启'), findsOneWidget);
    expect(find.text('打开设置'), findsOneWidget);
    await tester.ensureVisible(find.text('打开设置'));
    await tester.tap(find.text('打开设置'));
    await tester.pump();

    expect(launchCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('定位异步返回时页面已关闭不会更新已卸载的状态', (tester) async {
    final completer = Completer<CheckInLocationAccessResult>();
    CheckInLocationService.locationLoaderForTesting = () => completer.future;

    await tester.pumpWidget(_app(goal: _goal(requireLocation: true)));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    completer.complete(const CheckInLocationAccessResult(
      permissionStatus: CheckInLocationPermissionStatus.deniedForever,
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
