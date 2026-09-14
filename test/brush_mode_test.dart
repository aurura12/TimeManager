import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/home_screen.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'package:time_manager/services/on_this_day_service.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/widgets/brush_mode_card.dart';
import 'package:time_manager/widgets/time_grid.dart';

/// 刷子模式（事件优先选择）的验收测试。
///
/// 测试跑在 macOS 上，`isDesktopPlatform` 为 true，所以 HomeScreen 走的是
/// Windows 三列（`_DayGrid`）分支：每个 `_DayGrid` 自己把触点换算成
/// 「日期 + 槽位索引」再上报父页面。安卓的单列路径（TimeGrid 自带
/// `_calculateIndex` 的那条）由文件末尾的 `TimeGrid 刷子手势层` 分组直接覆盖。
///
/// 三列语义：[_prevColumn] / [_todayColumn] / 第三列（明天）。
const int _prevColumn = 0;
const int _todayColumn = 1;

/// 测试用的 GoogleSignInPlatform fake：避免 TimeProvider 初始化时
/// GoogleCalendarService.restoreSignIn 抛 UnimplementedError。
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

void _installPluginMocks({Map<String, Object> prefs = const {}}) {
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
    (call) async => '/tmp/time_manager_brush_test',
  );
}

/// 等 TimeProvider 本地数据加载完（未加载完时所有写操作都会被挡掉）。
Future<void> _pumpUntilReady(WidgetTester tester, TimeProvider provider) async {
  for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(provider.isInitialLoadFinished, isTrue, reason: 'TimeProvider 初始化未完成');
}

/// 把日程/分类的 Gitee 防抖定时器跑干净，避免测试结束时残留 pending timer。
Future<void> _drainPendingSync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 5));
  await tester.pump();
}

Future<TimeProvider> _pumpHome(
  WidgetTester tester, {
  Size size = const Size(1000, 800),
}) async {
  _installPluginMocks();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final provider = TimeProvider();
  await tester.pumpWidget(
    ChangeNotifierProvider<TimeProvider>.value(
      value: provider,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ),
  );
  await _pumpUntilReady(tester, provider);
  await tester.pump();
  await _drainPendingSync(tester);
  return provider;
}

/// 侧栏事件项 / 子事件项（都被包在 Slidable 里，用它把刷子卡片上的同名文字排除掉）
Finder _categoryItem(String name) => find.descendant(
      of: find.byType(Slidable),
      matching: find.text(name),
    );

Future<void> _tapCategory(WidgetTester tester, String name) async {
  await tester.tap(_categoryItem(name));
  await tester.pump();
}

Category _category(TimeProvider provider, String name) =>
    provider.categories.firstWhere((c) => c.name == name);

/// 网格几何：ListView 有 8 的上下内边距、行高 45，且被时间轴滚到
/// `startHour * 45`，所以要减掉这段滚动偏移才能换算成屏幕坐标。
class _GridGeometry {
  const _GridGeometry(this.rect, this.columnWidth, this.scrollOffset);

  final Rect rect;
  final double columnWidth;
  final double scrollOffset;

  Offset centerOf(int index) => Offset(
        rect.left + columnWidth * ((index % 6) + 0.5),
        rect.top +
            AppSpacing.sm +
            (index ~/ 6) * AppSizes.gridRow +
            AppSizes.gridRow / 2 -
            scrollOffset,
      );
}

_GridGeometry _gridGeometry(
  WidgetTester tester,
  TimeProvider provider,
  int column,
) {
  final rect = tester.getRect(find.byType(TimeGrid).at(column));
  return _GridGeometry(
    rect,
    rect.width / 6,
    provider.startHour * AppSizes.gridRow,
  );
}

Offset _visiblePoint(_GridGeometry geometry, int index) {
  final point = geometry.centerOf(index);
  expect(geometry.rect.contains(point), isTrue,
      reason: '触点 $point 落在网格 ${geometry.rect} 之外，测试的几何假设已失效');
  return point;
}

String? _labelAt(TimeProvider provider, int index) =>
    provider.slots[index].label;

String? _categoryIdAt(TimeProvider provider, int index) =>
    provider.slots[index].categoryId;

/// 一次连续拖动：按下 → 逐格移动 → 松手
Future<void> _brushStroke(WidgetTester tester, List<Offset> points) async {
  final gesture = await tester.startGesture(points.first);
  for (final point in points.skip(1)) {
    await gesture.moveTo(point);
  }
  await gesture.up();
  await tester.pump();
}

/// 一次被取消的刷子手势：按下 → 移动 → PointerCancel。
Future<void> _cancelBrushStroke(
    WidgetTester tester, List<Offset> points) async {
  final gesture = await tester.startGesture(points.first);
  for (final point in points.skip(1)) {
    await gesture.moveTo(point);
  }
  await gesture.cancel();
  await tester.pump();
}

/// 普通模式下点一个格子（只选中，不写数据）。
///
/// 网格行同时挂了 onTapDown 和双击删除，tap 识别器要等双击超时才会结束竞争，
/// 所以这里必须把时钟推过 kDoubleTapTimeout。
Future<void> _selectCell(WidgetTester tester, Offset point) async {
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('没有选中时间时，点击一级事件只进入刷子模式', (tester) async {
    final provider = await _pumpHome(tester);
    final revision = provider.slotsRevision;

    await _tapCategory(tester, '学习');

    expect(find.byType(BrushModeCard), findsOneWidget);
    expect(find.text('刷子模式'), findsOneWidget);
    // 没有写入任何时间数据
    expect(provider.slotsRevision, revision);
    expect(provider.slots.every((slot) => !slot.recorded), isTrue);

    await _drainPendingSync(tester);
  });

  testWidgets('没有选中时间时，点击子事件只进入刷子模式', (tester) async {
    final provider = await _pumpHome(tester);
    provider.setCategoryExpandState(_category(provider, '学习').id, true);
    await tester.pump();
    final revision = provider.slotsRevision;

    await _tapCategory(tester, '阅读');

    expect(find.byType(BrushModeCard), findsOneWidget);
    expect(find.text('学习 · 阅读'), findsOneWidget);
    expect(provider.slotsRevision, revision);

    await _drainPendingSync(tester);
  });

  testWidgets('进入刷子模式后时间数据保持不变', (tester) async {
    final provider = await _pumpHome(tester);
    final revision = provider.slotsRevision;

    await _tapCategory(tester, '学习');

    expect(provider.slotsRevision, revision);
    expect(provider.slots.where((slot) => slot.recorded), isEmpty);
    // 刷子模式也不会改动待分配的选中范围（进入时就清掉了）
    expect(find.byType(BrushModeCard), findsOneWidget);

    await _drainPendingSync(tester);
  });

  testWidgets('点击一个格子后正确写入父事件', (tester) async {
    final provider = await _pumpHome(tester);
    await _tapCategory(tester, '学习');
    final geometry = _gridGeometry(tester, provider, _todayColumn);

    await tester.tapAt(_visiblePoint(geometry, 54));
    await tester.pump();

    expect(_labelAt(provider, 54), '学习');
    expect(_categoryIdAt(provider, 54), _category(provider, '学习').id);
    expect(_labelAt(provider, 55), isNull);
    // 单击只写一格，且刷子模式保持开着
    expect(find.byType(BrushModeCard), findsOneWidget);

    await _drainPendingSync(tester);
  });

  testWidgets('点击一个格子后正确写入子事件', (tester) async {
    final provider = await _pumpHome(tester);
    provider.setCategoryExpandState(_category(provider, '学习').id, true);
    await tester.pump();
    await _tapCategory(tester, '阅读');
    final geometry = _gridGeometry(tester, provider, _todayColumn);

    await tester.tapAt(_visiblePoint(geometry, 54));
    await tester.pump();

    expect(_labelAt(provider, 54), '阅读');
    expect(_categoryIdAt(provider, 54), _category(provider, '学习').id);

    await _drainPendingSync(tester);
  });

  testWidgets('拖动多个格子只产生一次 Provider 写入', (tester) async {
    final provider = await _pumpHome(tester);
    await _tapCategory(tester, '学习');
    final geometry = _gridGeometry(tester, provider, _todayColumn);
    final revision = provider.slotsRevision;

    await _brushStroke(tester, [
      _visiblePoint(geometry, 54),
      _visiblePoint(geometry, 55),
      _visiblePoint(geometry, 60),
    ]);

    // 一次拖动 = 一次 slotsRevision（= 一次序列化/落盘/同步），不是三格三次
    expect(provider.slotsRevision, revision + 1);
    for (final index in [54, 55, 60]) {
      expect(_labelAt(provider, index), '学习', reason: '第 $index 格没写上');
    }

    await _drainPendingSync(tester);
  });

  testWidgets('一次拖动只产生一条撤销记录', (tester) async {
    final provider = await _pumpHome(tester);
    await _tapCategory(tester, '学习');
    final geometry = _gridGeometry(tester, provider, _todayColumn);

    await _brushStroke(tester, [
      _visiblePoint(geometry, 54),
      _visiblePoint(geometry, 55),
      _visiblePoint(geometry, 60),
    ]);
    for (final index in [54, 55, 60]) {
      expect(_labelAt(provider, index), '学习');
    }

    provider.undo();
    await tester.pump();

    for (final index in [54, 55, 60]) {
      expect(_labelAt(provider, index), isNull, reason: '一次撤销没退回第 $index 格');
    }

    await _drainPendingSync(tester);
  });

  testWidgets('桌面端取消刷子手势不会写入时间块', (tester) async {
    final provider = await _pumpHome(tester);
    await _tapCategory(tester, '学习');
    final geometry = _gridGeometry(tester, provider, _todayColumn);
    final revision = provider.slotsRevision;

    await _cancelBrushStroke(tester, [
      _visiblePoint(geometry, 54),
      _visiblePoint(geometry, 55),
    ]);

    expect(provider.slotsRevision, revision);
    expect(_labelAt(provider, 54), isNull);
    expect(_labelAt(provider, 55), isNull);
    // 取消的是当前笔画，不退出刷子模式。
    expect(find.byType(BrushModeCard), findsOneWidget);

    await _drainPendingSync(tester);
  });

  testWidgets('切换刷子事件不会修改已有时间', (tester) async {
    final provider = await _pumpHome(tester);
    await _tapCategory(tester, '学习');
    final revision = provider.slotsRevision;

    await _tapCategory(tester, '工作');

    expect(provider.slotsRevision, revision);
    expect(find.byType(BrushModeCard), findsOneWidget);
    expect(
      find.descendant(
          of: find.byType(BrushModeCard), matching: find.text('工作')),
      findsOneWidget,
    );

    // 换过刷子之后写的应该是新事件
    final geometry = _gridGeometry(tester, provider, _todayColumn);
    await tester.tapAt(_visiblePoint(geometry, 54));
    await tester.pump();
    expect(_labelAt(provider, 54), '工作');

    await _drainPendingSync(tester);
  });

  testWidgets('点击退出后再次点击时间格恢复普通选择', (tester) async {
    final provider = await _pumpHome(tester);
    await _tapCategory(tester, '学习');
    expect(find.byType(BrushModeCard), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byType(BrushModeCard), matching: find.text('退出')));
    await tester.pump();
    expect(find.byType(BrushModeCard), findsNothing);

    final geometry = _gridGeometry(tester, provider, _todayColumn);
    await _selectCell(tester, _visiblePoint(geometry, 54));
    // 退出后点格子只选中，不写入
    expect(_labelAt(provider, 54), isNull);
    expect(find.byType(BrushModeCard), findsNothing);

    // 再点事件 → 回到原来的「先选时间，再选事件」
    await _tapCategory(tester, '学习');
    expect(find.byType(BrushModeCard), findsNothing);
    expect(_labelAt(provider, 54), '学习');

    await _drainPendingSync(tester);
  });

  testWidgets('Android 返回键可以退出刷子模式', (tester) async {
    await _pumpHome(tester);
    await _tapCategory(tester, '学习');
    expect(find.byType(BrushModeCard), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.byType(BrushModeCard), findsNothing);
    // 只退出刷子模式，没有把页面弹掉
    expect(find.byType(HomeScreen), findsOneWidget);

    await _drainPendingSync(tester);
  });

  testWidgets('切换日期会退出刷子模式', (tester) async {
    await _pumpHome(tester);
    await _tapCategory(tester, '学习');
    expect(find.byType(BrushModeCard), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_forward_ios));
    await tester.pump();

    expect(find.byType(BrushModeCard), findsNothing);

    await _drainPendingSync(tester);
  });

  testWidgets('离开「记录」Tab 会退出刷子模式', (tester) async {
    // 预置「那年今日已弹过」标记，避免 MainScreen 拉起日记索引轮询
    _installPluginMocks(prefs: {
      'on_this_day_last_shown_date': OnThisDayService.dateKeyOf(DateTime.now()),
    });
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = TimeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<TimeProvider>.value(
        value: provider,
        child: MaterialApp(theme: AppTheme.light(), home: const MainScreen()),
      ),
    );
    await _pumpUntilReady(tester, provider);
    await tester.pump(const Duration(milliseconds: 300));

    await _tapCategory(tester, '学习');
    expect(find.byType(BrushModeCard), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('日记')));
    await tester.pump();
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('记录')));
    await tester.pump();

    // 回到「记录」页时刷子已经关了（IndexedStack 不会 dispose，靠 key 主动退出）
    expect(find.byType(BrushModeCard), findsNothing);

    await _drainPendingSync(tester);
  });

  testWidgets('旧的「先选时间，再选事件」逻辑仍然正常', (tester) async {
    final provider = await _pumpHome(tester);
    final geometry = _gridGeometry(tester, provider, _todayColumn);

    await _selectCell(tester, _visiblePoint(geometry, 54));

    await _tapCategory(tester, '学习');

    expect(find.byType(BrushModeCard), findsNothing);
    expect(_labelAt(provider, 54), '学习');

    await _drainPendingSync(tester);
  });

  testWidgets('Windows 三列记录使用正确的日期', (tester) async {
    final provider = await _pumpHome(tester);
    final today = provider.currentDate;
    final prevDate = today.subtract(const Duration(days: 1));
    final nextDate = today.add(const Duration(days: 1));

    await _tapCategory(tester, '学习');
    final geometry = _gridGeometry(tester, provider, _prevColumn);

    await tester.tapAt(_visiblePoint(geometry, 54));
    await tester.pump();

    expect(provider.slotsForDate(prevDate)[54].label, '学习');
    // 不串写今天和明天
    expect(provider.slotsForDate(today)[54].label, isNull);
    expect(provider.slotsForDate(nextDate)[54].label, isNull);
    expect(_labelAt(provider, 54), isNull);

    await _drainPendingSync(tester);
  });

  testWidgets('临时事件仍然要求先选时间', (tester) async {
    final provider = await _pumpHome(tester);
    final revision = provider.slotsRevision;

    await _tapCategory(tester, '临时');

    expect(find.byType(BrushModeCard), findsNothing);
    expect(find.text('请先在左侧网格中选择时间块'), findsOneWidget);
    expect(provider.slotsRevision, revision);

    await _drainPendingSync(tester);
  });

  group('TimeGrid 刷子手势层（安卓单列路径）', () {
    Future<TimeProvider> pumpGrid(
      WidgetTester tester, {
      required bool brushMode,
      required List<Offset> brushEvents,
      required List<Offset> selectionEvents,
      required VoidCallback onBrushUp,
      required VoidCallback onBrushCancel,
    }) async {
      _installPluginMocks();
      final provider = TimeProvider();
      final gridKey = GlobalKey();
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

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
                  controller: scrollController,
                  dragStartIndex: null,
                  dragEndIndex: null,
                  brushMode: brushMode,
                  brushPreviewIndices:
                      brushMode ? const <int>{0, 1} : const <int>{},
                  onBrushPointerDown: brushMode
                      ? (position) => brushEvents.add(position)
                      : null,
                  onBrushPointerMove: brushMode
                      ? (position) => brushEvents.add(position)
                      : null,
                  onBrushPointerUp: brushMode ? onBrushUp : null,
                  onBrushPointerCancel: brushMode ? onBrushCancel : null,
                  onTapDown: (position) => selectionEvents.add(position),
                  onPanStart: (position) => selectionEvents.add(position),
                  onPanUpdate: (position) => selectionEvents.add(position),
                  onRemoveSlot: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await _pumpUntilReady(tester, provider);
      await tester.pump();
      return provider;
    }

    testWidgets('刷子模式下只上报指针事件，点选/拖选不再触发', (tester) async {
      final brushEvents = <Offset>[];
      final selectionEvents = <Offset>[];
      var brushUps = 0;
      await pumpGrid(
        tester,
        brushMode: true,
        brushEvents: brushEvents,
        selectionEvents: selectionEvents,
        onBrushUp: () => brushUps++,
        onBrushCancel: () {},
      );

      final center = tester.getCenter(find.byType(TimeGrid));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(0, AppSizes.gridRow));
      await gesture.up();
      await tester.pump();

      expect(brushEvents, hasLength(2), reason: '应该收到 1 次 down + 1 次 move');
      expect(brushUps, 1);
      expect(selectionEvents, isEmpty, reason: '刷子模式下不能再走选中逻辑');
      expect(tester.takeException(), isNull);
      await _drainPendingSync(tester);
    });

    testWidgets('普通模式不改行为：仍是点选与拖选', (tester) async {
      final brushEvents = <Offset>[];
      final selectionEvents = <Offset>[];
      await pumpGrid(
        tester,
        brushMode: false,
        brushEvents: brushEvents,
        selectionEvents: selectionEvents,
        onBrushUp: () {},
        onBrushCancel: () {},
      );

      final center = tester.getCenter(find.byType(TimeGrid));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(selectionEvents, hasLength(1), reason: '单击应该触发 onTapDown');
      expect(brushEvents, isEmpty);

      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(0, AppSizes.gridRow));
      await gesture.up();
      await tester.pump();
      expect(selectionEvents.length, greaterThan(1),
          reason: '拖动应该触发 onPanStart/Update');
      expect(brushEvents, isEmpty, reason: '普通模式不安装刷子监听');
      expect(tester.takeException(), isNull);
      await _drainPendingSync(tester);
    });

    testWidgets('刷子模式取消指针只触发取消回调，不触发松手回调', (tester) async {
      final brushEvents = <Offset>[];
      final selectionEvents = <Offset>[];
      var brushUps = 0;
      var brushCancels = 0;
      await pumpGrid(
        tester,
        brushMode: true,
        brushEvents: brushEvents,
        selectionEvents: selectionEvents,
        onBrushUp: () => brushUps++,
        onBrushCancel: () => brushCancels++,
      );

      final center = tester.getCenter(find.byType(TimeGrid));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(0, AppSizes.gridRow));
      await gesture.cancel();
      await tester.pump();

      expect(brushUps, 0);
      expect(brushCancels, 1);
      expect(brushEvents, hasLength(2), reason: '应该收到 1 次 down + 1 次 move');
      expect(selectionEvents, isEmpty);
      expect(tester.takeException(), isNull);
      await _drainPendingSync(tester);
    });
  });
}
