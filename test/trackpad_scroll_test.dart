import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/home_screen.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/time_grid.dart';

/// macOS 触控板双指上下滑动是 pan-zoom 事件（不是滚轮事件）。
/// 网格不能把它当成拖选，否则滚不动还会选中一片格子。

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

void _installPluginMocks(Map<String, Object> prefs) {
  SharedPreferences.setMockInitialValues(prefs);
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
    (call) async => '/tmp/time_manager_trackpad_test',
  );
}

Future<void> _pumpUntilReady(WidgetTester tester, TimeProvider provider) async {
  for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(provider.isInitialLoadFinished, isTrue);
}

/// 触控板双指滑动：pan 为累计位移，分两步推过拖动阈值。
Future<void> _trackpadPan(
  WidgetTester tester,
  Offset location,
  Offset pan,
) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
  await gesture.panZoomStart(location);
  await tester.pump();
  await gesture.panZoomUpdate(location, pan: pan / 2);
  await tester.pump();
  await gesture.panZoomUpdate(location, pan: pan);
  await tester.pump();
  await gesture.panZoomEnd();
  await tester.pump();
}

Finder get _timeAxis => find.byKey(const ValueKey('home-time-axis'));

ScrollController _axisController(WidgetTester tester) =>
    tester.widget<ListView>(_timeAxis).controller!;

void main() {
  testWidgets('触控板滑动网格：不选格（鼠标拖动仍然选格）', (tester) async {
    _installPluginMocks(<String, Object>{
      'categories': <String>[],
      'daily_slots': jsonEncode(<String, Object>{}),
    });

    final provider = TimeProvider();
    final pans = <Offset>[];
    final taps = <Offset>[];
    final gridKey = GlobalKey();
    final gridController = ScrollController();
    addTearDown(gridController.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<TimeProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 400,
              child: TimeGrid(
                gridKey: gridKey,
                controller: gridController,
                dragStartIndex: null,
                dragEndIndex: null,
                onTapDown: taps.add,
                onPanStart: pans.add,
                onPanUpdate: pans.add,
                onRemoveSlot: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpUntilReady(tester, provider);
    await tester.pump();

    final center = tester.getCenter(find.byType(TimeGrid));
    await _trackpadPan(tester, center, const Offset(0, -60));
    expect(pans, isEmpty, reason: '触控板滚动不能变成拖选');
    expect(taps, isEmpty);

    // 鼠标拖动必须仍然能拖选，别把桌面端自己的手势一起关掉。
    final mouse = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await mouse.moveBy(const Offset(0, -60));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(pans, isNotEmpty);
    // 双击识别器还挂着一个 40ms 的计时器，等它走完再结束测试。
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('触控板滑动三列网格：滚动共享时间轴，且不产生选区', (tester) async {
    _installPluginMocks(<String, Object>{
      'categories': <String>[],
      'daily_slots': jsonEncode(<String, Object>{}),
    });
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime(2026, 10, 29, 15, 30);
    final provider = TimeProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TimeProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => DesktopLayoutProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: HomeScreen(clock: () => now),
        ),
      ),
    );
    await _pumpUntilReady(tester, provider);
    await tester.pump(const Duration(seconds: 5));

    final grids = find.byType(TimeGrid);
    expect(grids, findsNWidgets(3), reason: '桌面端是昨天/今天/明天三列');
    final axis = _axisController(tester);
    // 先离开「现在」的自动定位（可能正好在底部），滚动方向才可断言。
    axis.jumpTo(100);
    await tester.pump();
    final before = axis.offset;

    await _trackpadPan(
      tester,
      tester.getCenter(grids.at(1)),
      const Offset(0, -40),
    );

    expect(
      axis.offset,
      closeTo(before + 40, 1),
      reason: '触控板下滑（pan 为负）应把时间轴往下滚',
    );
    for (final grid in tester.widgetList<TimeGrid>(find.byType(TimeGrid))) {
      expect(grid.dragStartIndex, isNull);
      expect(grid.dragEndIndex, isNull);
    }
  });
}
