import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/menu_bar_panel.dart';
import 'package:time_manager/widgets/menu_bar_target_dial.dart';

class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
          AttemptLightweightAuthenticationParameters params) async =>
      null;

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
          ClientAuthorizationTokensForScopesParameters params) async =>
      null;

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
          ServerAuthorizationTokensForScopesParameters params) async =>
      null;

  @override
  Future<void> clearAuthorizationToken(
      ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

Future<TimeProvider> _createProvider(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
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

  final provider = await tester.runAsync(() async {
    final created = TimeProvider();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!created.isInitialLoadFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return created;
  });
  return provider!;
}

/// 网格里一个不被浮层盖住的点：滚轮事件必须落在时间轴上，不能落在转盘上。
Offset _pointOutside(Rect dial, Rect grid) {
  final candidates = <Offset>[
    Offset(grid.center.dx, grid.top + 12),
    Offset(grid.center.dx, grid.bottom - 12),
    Offset(grid.left + 20, grid.center.dy),
    Offset(grid.right - 12, grid.bottom - 12),
  ];
  for (final point in candidates) {
    if (!dial.contains(point)) return point;
  }
  return candidates.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('拖选后转盘升起，点中间项写入当天记录', (tester) async {
    final provider = await _createProvider(tester);
    provider.addCategory(
      Category(id: 'work', name: '工作', color: Colors.blue),
    );
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);

    tester.view.physicalSize = const Size(400, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<TimeProvider?>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 720, child: MenuBarPanel()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 先在格子上拖选一段时间，松手后转盘升起；点中间的分类立即写入。
    await tester.drag(
      find.byKey(const ValueKey('menu-bar-time-grid')),
      const Offset(0, 40),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.byType(MenuBarTargetDial), findsOneWidget);
    // 浮层不再占底部高度：网格高度不因转盘出现而变化。
    final gridRect = tester.getRect(
      find.byKey(const ValueKey('menu-bar-time-grid')),
    );
    final dialRect = tester.getRect(find.byType(MenuBarTargetDial));
    expect(dialRect.left, greaterThanOrEqualTo(gridRect.left));
    expect(dialRect.bottom, lessThanOrEqualTo(gridRect.bottom));

    // 滚轮在网格空白处仍然滚时间轴，浮层跟着选区一起移动。
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(_pointOutside(dialRect, gridRect)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    final movedRect = tester.getRect(find.byType(MenuBarTargetDial));
    expect(movedRect.top, isNot(closeTo(dialRect.top, 0.5)));
    expect(find.textContaining('已选'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();

    final recorded = provider
        .slotsForDate(day)
        .where((slot) => slot.recorded)
        .toList(growable: false);
    expect(recorded, isNotEmpty);
    expect(recorded.first.label, '工作');

    // 卸载树并停掉 Provider 的防抖定时器，避免测试结束时残留 timer。
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
    await tester.pump();
  });

  testWidgets('触控板双指滑动：滚时间轴，不选格', (tester) async {
    final provider = await _createProvider(tester);
    provider.addCategory(
      Category(id: 'work', name: '工作', color: Colors.blue),
    );

    tester.view.physicalSize = const Size(400, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<TimeProvider?>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 720, child: MenuBarPanel()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 面板里只有时间轴是可滚动的，网格那层是 NeverScrollable 的 ListView。
    final axis = tester
        .widget<ListView>(find.byWidgetPredicate(
          (widget) => widget is ListView && widget.physics == null,
        ))
        .controller!;
    axis.jumpTo(100);
    await tester.pump();
    final before = axis.offset;

    // macOS 触控板上双指滑动是 pan-zoom 事件，不是滚轮事件。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    final center =
        tester.getCenter(find.byKey(const ValueKey('menu-bar-time-grid')));
    await gesture.panZoomStart(center);
    await tester.pump();
    await gesture.panZoomUpdate(center, pan: const Offset(0, -20));
    await tester.pump();
    await gesture.panZoomUpdate(center, pan: const Offset(0, -40));
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pump();

    expect(axis.offset, closeTo(before + 40, 1));
    expect(
      find.byType(MenuBarTargetDial),
      findsNothing,
      reason: '触控板滚动不能变成拖选',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
    await tester.pump();
  });
}