import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:time_manager/screens/diary_screen.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/utils/swipe_navigation.dart';

String _dateLabel(DateTime date) => DateFormat('yyyy年M月d日').format(date);

class _FailBodyStore extends InMemorySharedPreferencesStore {
  _FailBodyStore(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.startsWith('flutter.diary_draft_g_')) return false;
    return super.setValue(valueType, key, value);
  }
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
    (call) async => '/tmp/time_manager_diary_swipe_test',
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') return null;
    return null;
  });
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

Future<void> _pumpDiary(WidgetTester tester) async {
  _installPluginMocks();
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light(), home: const DiaryScreen()),
  );
  await _pumpUntil(tester, find.byIcon(Icons.chevron_left));
  expect(find.byIcon(Icons.chevron_left), findsOneWidget);
}

/// 页面左内边距（16）之外的细条，落在编辑框外，可安全起手。
const _outsideEditor = Offset(8, 320);

void main() {
  setUp(AppIdentityService.resetForTesting);
  tearDown(AppIdentityService.resetForTesting);

  group('resolveSwipeNavigation', () {
    test('左滑是后一天，右滑是前一天', () {
      expect(
        resolveSwipeNavigation(dx: -80, dy: 4, velocityX: -400),
        SwipeNavigationDirection.next,
      );
      expect(
        resolveSwipeNavigation(dx: 80, dy: 4, velocityX: 400),
        SwipeNavigationDirection.previous,
      );
    });

    test('位移不足且速度不够时不触发', () {
      expect(resolveSwipeNavigation(dx: -20, dy: 0, velocityX: -100), isNull);
    });

    test('竖向位移更大时不触发（更像滚动）', () {
      expect(resolveSwipeNavigation(dx: -60, dy: 90, velocityX: -400), isNull);
    });

    test('位移不足但快速轻扫仍可触发', () {
      expect(
        resolveSwipeNavigation(dx: -10, dy: 2, velocityX: -900),
        SwipeNavigationDirection.next,
      );
    });
  });

  testWidgets('编辑框外左滑进入后一天，右滑回到前一天', (tester) async {
    final today = DateTime.now();
    await _pumpDiary(tester);
    expect(find.text(_dateLabel(today)), findsOneWidget);

    await tester.dragFrom(_outsideEditor, const Offset(-200, 0));
    await _pumpUntil(tester, find.text(_dateLabel(today.add(const Duration(days: 1)))));
    expect(
      find.text(_dateLabel(today.add(const Duration(days: 1)))),
      findsOneWidget,
    );

    await tester.dragFrom(_outsideEditor, const Offset(200, 0));
    await _pumpUntil(tester, find.text(_dateLabel(today)));
    expect(find.text(_dateLabel(today)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑框内横向拖动只做文字操作，不切日', (tester) async {
    final today = DateTime.now();
    await _pumpDiary(tester);

    await tester.drag(find.byType(TextField), const Offset(-200, 0));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(_dateLabel(today)), findsOneWidget);
  });

  testWidgets('位移不足或竖向拖动都不切日', (tester) async {
    final today = DateTime.now();
    await _pumpDiary(tester);

    await tester.dragFrom(_outsideEditor, const Offset(-20, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_dateLabel(today)), findsOneWidget);

    await tester.dragFrom(_outsideEditor, const Offset(-30, 160));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_dateLabel(today)), findsOneWidget);
  });

  testWidgets('鼠标拖动不切日', (tester) async {
    final today = DateTime.now();
    await _pumpDiary(tester);

    await tester.dragFrom(
      _outsideEditor,
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(_dateLabel(today)), findsOneWidget);
  });

  testWidgets('本地保存失败时滑动不切日', (tester) async {
    final today = DateTime.now();
    await _pumpDiary(tester);
    // 必须在 _pumpDiary 之后替换，否则 setMockInitialValues 会把 store 重置。
    SharedPreferencesStorePlatform.instance = _FailBodyStore(<String, Object>{});

    await tester.enterText(find.byType(TextField), '还没落盘的内容');
    await tester.pump(const Duration(milliseconds: 50));

    await tester.dragFrom(_outsideEditor, const Offset(-200, 0));
    await _pumpUntil(tester, find.text('本地保存失败，暂时无法切换日记，请检查存储空间'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(_dateLabel(today)), findsOneWidget);
    expect(
      find.text('本地保存失败，暂时无法切换日记，请检查存储空间'),
      findsOneWidget,
    );
  });
}
