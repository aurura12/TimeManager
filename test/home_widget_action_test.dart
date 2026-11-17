import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/services/home_widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HomeWidgetService.parseActionUri', () {
    test('生成的动作 URI 都能严格往返解析', () {
      for (final action in [
        HomeWidgetAction.todayRecords,
        HomeWidgetAction.search,
        HomeWidgetAction.syncCenter,
      ]) {
        final uri = HomeWidgetService.actionUri(action);
        final request = HomeWidgetService.parseActionUri(uri);

        expect(request, isNotNull);
        expect(request!.action, action);
        expect(request.routeName, startsWith('/widget/'));
      }
    });

    test('快捷入口分别映射到明确的页面路由', () {
      expect(
        HomeWidgetService.parseActionUri(
          HomeWidgetService.actionUri(HomeWidgetAction.todayRecords),
        )!
            .routeName,
        '/widget/today-records',
      );
      expect(
        HomeWidgetService.parseActionUri(
          HomeWidgetService.actionUri(HomeWidgetAction.search),
        )!
            .routeName,
        '/widget/search',
      );
      expect(
        HomeWidgetService.parseActionUri(
          HomeWidgetService.actionUri(HomeWidgetAction.syncCenter),
        )!
            .routeName,
        '/widget/sync-center',
      );
    });

    test('null 表示普通启动，恶意或未知参数会被标记为无效', () {
      expect(HomeWidgetService.parseActionUri(null), isNull);

      final invalidUris = [
        Uri.parse('time-manager://other?action=search'),
        Uri.parse('https://widget?action=search'),
        Uri.parse('time-manager://widget?action=unknown'),
        Uri.parse('time-manager://widget?action=search&extra=value'),
        Uri.parse('time-manager://widget?action=search&action=today_records'),
        Uri.parse('time-manager://widget/path?action=search'),
        Uri.parse('time-manager://widget?action=search#fragment'),
        Uri.parse('time-manager://widget:443?action=search'),
      ];

      for (final uri in invalidUris) {
        expect(
          HomeWidgetService.parseActionUri(uri)?.action,
          HomeWidgetAction.invalid,
          reason: '应拒绝 $uri',
        );
      }
    });

    test('invalid 动作不能重新生成可执行 URI', () {
      expect(
        () => HomeWidgetService.actionUri(HomeWidgetAction.invalid),
        throwsArgumentError,
      );
    });
  });

  group('HomeWidgetService.updateFromDay', () {
    test('只写数据键，不覆盖外观数据', () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('home_widget'),
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('home_widget'),
          null,
        ),
      );

      final slots = List<TimeSlot>.generate(
        144,
        (index) => TimeSlot(hour: index ~/ 6, minute10: index % 6),
      );
      await HomeWidgetService.updateFromDay(
        slots: slots,
        date: DateTime(2026, 5, 26),
        pendingSync: true,
      );

      final savedIds = calls
          .where((call) => call.method == 'saveWidgetData')
          .map((call) => (call.arguments as Map)['id'] as String)
          .toSet();
      expect(savedIds, {
        'widget_date',
        'widget_stats',
        'widget_top_categories',
        'widget_current',
        'widget_next',
        'widget_timeline_blocks',
        'widget_pending_sync',
        'widget_is_today',
        'widget_now_minutes',
        'widget_day_start_minutes',
        'widget_day_span_minutes',
      });
      expect(savedIds, isNot(contains(HomeWidgetService.widgetThemeKey)));
      expect(calls.where((call) => call.method == 'updateWidget'), hasLength(1));
    });
  });

  group('HomeWidgetService.updateAppearance', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('home_widget'),
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('home_widget'), null),
      );
    });

    test('受支持时写入外观并触发一次重绘', () async {
      await HomeWidgetService.updateAppearance('{"v":1}', supported: true);

      final savedIds = calls
          .where((call) => call.method == 'saveWidgetData')
          .map((call) => (call.arguments as Map)['id'] as String)
          .toSet();
      expect(savedIds, {HomeWidgetService.widgetThemeKey});
      expect(calls.where((call) => call.method == 'updateWidget'), hasLength(1));
    });

    test('非 Android 不碰通道', () async {
      await HomeWidgetService.updateAppearance('{"v":1}', supported: false);

      expect(calls, isEmpty);
    });
  });
}
