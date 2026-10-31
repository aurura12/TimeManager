import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/check_in_document.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/providers/desktop_layout_provider.dart';
import 'package:time_manager/providers/haptics_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/home_screen.dart';
import 'package:time_manager/services/check_in_location_service.dart';
import 'package:time_manager/services/check_in_sync_service.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/widgets/check_in_photo_sheet.dart';
import 'package:time_manager/widgets/time_grid.dart';

import 'support/fake_main_tab_preferences_store.dart';

/// 触感反馈（P2-1）：动作 → 震动强度，以及「设置里关掉后完全不震」。
///
/// 触感统一走 `SystemChannels.platform` 的 `HapticFeedback.vibrate`，
/// 参数就是具体强度；这里直接把参数记下来断言。
const _selection = 'HapticFeedbackType.selectionClick';
const _light = 'HapticFeedbackType.lightImpact';
const _medium = 'HapticFeedbackType.mediumImpact';

/// 三列语义：左 / 今天 / 明天
const _todayColumn = 1;

class _Haptics {
  final List<String> events = <String>[];

  int countOf(String type) => events.where((event) => event == type).length;

  int get total => events.length;
}

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _gridKey(DateTime date) => '${date.year}-${date.month}-${date.day}';

List<String> _seedCategoriesJson() => [
      jsonEncode(Category(
        name: '学习',
        color: const Color(0xFF9CB86A),
        subCategories: ['阅读', '编程'],
        updatedAt: 100,
      ).toJson()),
      jsonEncode(Category(
        name: '工作',
        color: const Color(0xFF5B8DEF),
        updatedAt: 100,
      ).toJson()),
    ];

/// 种一条 09:00（索引 54）的记录，供拖边界与双击删除使用。
Map<String, Object> _seedPrefsWithRecordedSlot({Map<String, Object>? extra}) {
  final key = _dateKey(DateTime.now());
  return {
    'categories': _seedCategoriesJson(),
    'daily_slots': jsonEncode({
      key: [
        {'i': 54, 'l': '学习', 'c': 0xFF9CB86A, 'ts': 1},
      ],
    }),
    ...?extra,
  };
}

_Haptics _installPluginMocks(Map<String, Object> prefs) {
  SharedPreferences.setMockInitialValues(prefs);
  final haptics = _Haptics();
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
    (call) async => '/tmp/time_manager_haptics_test',
  );
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') {
      haptics.events.add((call.arguments as String?) ?? 'default');
    }
    return null;
  });
  return haptics;
}

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

class _HomeHarness {
  _HomeHarness(this.provider, this.haptics, this.hapticsProvider);

  final TimeProvider provider;
  final _Haptics haptics;
  final HapticsProvider hapticsProvider;
}

Future<_HomeHarness> _pumpHome(
  WidgetTester tester, {
  Map<String, Object>? prefs,
  bool withHapticsProvider = true,
}) async {
  final haptics = _installPluginMocks(prefs ?? _seedPrefsWithRecordedSlot());
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final provider = TimeProvider();
  final hapticsProvider = HapticsProvider();
  addTearDown(hapticsProvider.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<TimeProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => DesktopLayoutProvider()),
        if (withHapticsProvider)
          ChangeNotifierProvider<HapticsProvider?>.value(value: hapticsProvider),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        // 固定到 00:10，让"滚到现在"落在顶部，测试用的 54 号槽位仍在视口内。
        home: HomeScreen(clock: () => DateTime(2026, 1, 1, 0, 10)),
      ),
    ),
  );
  await _pumpUntilReady(tester, provider);
  await tester.pump();
  await _drainPendingSync(tester);
  return _HomeHarness(provider, haptics, hapticsProvider);
}

Finder _categoryItem(String name) => find.descendant(
      of: find.byType(Slidable),
      matching: find.text(name),
    );

/// 侧栏分类项当前文案可能被别的同名组件干扰，这里统一按 Slidable 内文本点。
Future<void> _tapCategory(WidgetTester tester, String name) async {
  await tester.tap(_categoryItem(name));
  await tester.pump();
}

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

_GridGeometry _gridGeometry(WidgetTester tester, int column) {
  final grid = tester.widget<TimeGrid>(find.byType(TimeGrid).at(column));
  final rect = tester.getRect(find.byType(TimeGrid).at(column));
  final offset = grid.controller.hasClients ? grid.controller.offset : 0.0;
  return _GridGeometry(rect, rect.width / 6, offset);
}

Offset _visiblePoint(_GridGeometry geometry, int index) {
  final point = geometry.centerOf(index);
  expect(geometry.rect.contains(point), isTrue,
      reason: '触点 $point 落在网格 ${geometry.rect} 之外，测试的几何假设已失效');
  return point;
}

/// 一次连续刷子拖动：按下 → 逐格移动 → 松手
Future<void> _brushStroke(WidgetTester tester, List<Offset> points) async {
  final gesture = await tester.startGesture(points.first);
  for (final point in points.skip(1)) {
    await gesture.moveTo(point);
  }
  await gesture.up();
  await tester.pump();
}

Future<void> _doubleTapAt(WidgetTester tester, Offset point) async {
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 400));
}

CheckInGoal _goal() => CheckInGoal(
      id: 'goal-1',
      ownerId: 'owner-1',
      ownerEmail: 'owner@example.com',
      name: '阅读',
      description: '',
      color: const Color(0xFF9CB86A),
      icon: Icons.menu_book,
      period: CheckInPeriod.daily,
      targetCount: 1,
      requirePhoto: false,
      requireLocation: false,
    );

class _FakeCheckInSync extends CheckInSyncService {
  _FakeCheckInSync(this.result);

  final CheckInSyncResult result;

  @override
  Future<CheckInSyncResult> submitCheckIn({
    required CheckInGoal goal,
    File? photoFile,
    CheckInLocationResult? location,
    DateTime? backfillDate,
    bool isBackfill = false,
  }) async {
    return result;
  }
}

Future<void> _pumpCheckInSheet(
  WidgetTester tester,
  _FakeCheckInSync sync,
) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final hapticsProvider = HapticsProvider();
  addTearDown(hapticsProvider.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<HapticsProvider?>.value(
      value: hapticsProvider,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<bool>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      CheckInPhotoSheet(goal: _goal(), syncService: sync),
                ),
                child: const Text('打开打卡'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('打开打卡'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
  });

  group('HapticsProvider', () {
    test('默认开启，关闭后重启仍然关闭', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = HapticsProvider();
      await provider.ready;
      expect(provider.enabled, isTrue);

      await provider.setEnabled(false);
      expect(provider.enabled, isFalse);

      final reopened = HapticsProvider();
      await reopened.ready;
      expect(reopened.enabled, isFalse);
    });

    test('脏值按默认开启处理', () async {
      SharedPreferences.setMockInitialValues({'app_haptics_v1': 'off'});
      final provider = HapticsProvider();
      await provider.ready;
      expect(provider.enabled, isTrue);
    });

    test('落盘失败回滚内存状态并抛错', () async {
      SharedPreferences.setMockInitialValues({});
      final store = FakeMainTabPreferencesStore(rejectWrites: true);
      SharedPreferencesStorePlatform.instance = store;

      final provider = HapticsProvider();
      await provider.ready;
      expect(provider.enabled, isTrue);

      await expectLater(provider.setEnabled(false), throwsStateError);
      expect(provider.enabled, isTrue, reason: '写盘失败必须回滚，不能显示已关闭');

      store.rejectWrites = false;
      await provider.setEnabled(false);
      expect(provider.enabled, isFalse);
    });
  });

  group('记录页手势', () {
    testWidgets('刷子每刷进一格震一次，松手不再重复', (tester) async {
      final harness = await _pumpHome(tester);
      await _tapCategory(tester, '学习');
      final geometry = _gridGeometry(tester, _todayColumn);
      harness.haptics.events.clear();

      await _brushStroke(tester, [
        _visiblePoint(geometry, 54),
        _visiblePoint(geometry, 55),
        _visiblePoint(geometry, 60),
      ]);

      expect(harness.haptics.countOf(_selection), 3,
          reason: '三格各一次，松手不额外震');
      expect(harness.haptics.countOf(_light), 0);
      expect(tester.takeException(), isNull);

      await _drainPendingSync(tester);
    });

    testWidgets('关掉触感反馈后刷子完全不震', (tester) async {
      final harness = await _pumpHome(
        tester,
        prefs: _seedPrefsWithRecordedSlot(extra: {'app_haptics_v1': false}),
      );
      // 等开关读盘完成
      await tester.pump();
      expect(harness.hapticsProvider.enabled, isFalse);

      await _tapCategory(tester, '学习');
      final geometry = _gridGeometry(tester, _todayColumn);
      harness.haptics.events.clear();

      await _brushStroke(tester, [
        _visiblePoint(geometry, 54),
        _visiblePoint(geometry, 55),
      ]);

      expect(harness.haptics.total, 0);
      expect(harness.provider.slots[54].label, '学习',
          reason: '震动只是反馈，不能影响刷子本身');
      await _drainPendingSync(tester);
    });

    testWidgets('拖边界每跨一格震一次，松手提交再震一次', (tester) async {
      final harness = await _pumpHome(tester);
      final date = harness.provider.currentDate;
      final handle = find.byKey(
        ValueKey('grid-resize-end-${_gridKey(date)}:9:54'),
      );
      expect(handle, findsOneWidget);

      final columnWidth =
          tester.getSize(find.byType(TimeGrid).at(_todayColumn)).width / 6;
      final gesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
      );
      await gesture.moveBy(Offset(columnWidth, 0));
      await tester.pump();
      expect(harness.haptics.countOf(_selection), 1);

      await gesture.up();
      await tester.pump();

      expect(harness.haptics.countOf(_light), 1, reason: '提交成功一次确认');
      expect(harness.provider.slots[55].recorded, isTrue);

      await _drainPendingSync(tester);
    });

    testWidgets('双击删除有内容的格子震一次，空格位不震', (tester) async {
      final harness = await _pumpHome(tester);
      final geometry = _gridGeometry(tester, _todayColumn);
      harness.haptics.events.clear();

      await _doubleTapAt(tester, _visiblePoint(geometry, 54));
      expect(harness.haptics.countOf(_light), 1);
      expect(harness.provider.slots[54].recorded, isFalse);

      await _doubleTapAt(tester, _visiblePoint(geometry, 55));
      expect(harness.haptics.countOf(_light), 1, reason: '空格位不该震');
      expect(tester.takeException(), isNull);

      await _drainPendingSync(tester);
    });

    testWidgets('没有注册触感开关的宿主按默认开启，且不抛异常', (tester) async {
      final harness = await _pumpHome(tester, withHapticsProvider: false);
      await _tapCategory(tester, '学习');
      final geometry = _gridGeometry(tester, _todayColumn);
      harness.haptics.events.clear();

      await _brushStroke(tester, [_visiblePoint(geometry, 54)]);

      expect(harness.haptics.countOf(_selection), 1);
      expect(tester.takeException(), isNull);
      await _drainPendingSync(tester);
    });
  });

  group('打卡', () {
    testWidgets('打卡成功震一次，失败不震', (tester) async {
      final haptics = _installPluginMocks({});
      await _pumpCheckInSheet(
        tester,
        _FakeCheckInSync(CheckInSyncResult.ok(CheckInDocument.empty)),
      );

      await tester.tap(find.text('不拍照，直接打卡'));
      await tester.pumpAndSettle();

      expect(haptics.countOf(_medium), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('打卡失败保持静默', (tester) async {
      final haptics = _installPluginMocks({});
      await _pumpCheckInSheet(
        tester,
        _FakeCheckInSync(CheckInSyncResult.fail('网络异常')),
      );

      await tester.tap(find.text('不拍照，直接打卡'));
      await tester.pumpAndSettle();

      expect(haptics.total, 0);
      expect(find.text('网络异常'), findsOneWidget);
    });
  });
}
