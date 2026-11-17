import 'dart:convert';

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
        'widget_date_epoch_day',
        'widget_text_by_slot',
        'widget_now_minutes',
        'widget_day_start_minutes',
        'widget_day_span_minutes',
      });
      expect(savedIds, isNot(contains(HomeWidgetService.widgetThemeKey)));
      expect(
          calls.where((call) => call.method == 'updateWidget'), hasLength(1));

      Object? savedValue(String id) => calls
          .firstWhere((call) =>
              call.method == 'saveWidgetData' &&
              (call.arguments as Map)['id'] == id)
          .arguments['data'];
      // 原生用 LocalDate.toEpochDay 比对"数据是哪天"，两边必须同口径。
      expect(savedValue('widget_date_epoch_day'), 20599);
    });

    test('预计算每个槽位的当前/接下来文案，并保留凌晨时段', () async {
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
      // 02:00-02:20「深夜」+ 09:00-09:20「工作」
      for (final index in [12, 13]) {
        slots[index]
          ..recorded = true
          ..label = '深夜';
      }
      for (final index in [54, 55]) {
        slots[index]
          ..recorded = true
          ..label = '工作';
      }

      await HomeWidgetService.updateFromDay(
        slots: slots,
        date: DateTime(2026, 5, 26),
        pendingSync: false,
      );

      Object? savedValue(String id) => calls
          .firstWhere((call) =>
              call.method == 'saveWidgetData' &&
              (call.arguments as Map)['id'] == id)
          .arguments['data'];

      final textBySlot =
          json.decode(savedValue('widget_text_by_slot') as String) as List;
      expect(textBySlot, hasLength(144));
      expect(textBySlot[12], ['当前：深夜', '接下来：工作 09:00']);
      expect(textBySlot[55], ['当前：工作', '接下来：无']);
      expect(textBySlot[100], ['当前：未记录', '接下来：无']);

      // 时间轴数据不再裁掉 7:00 之前的时段，原生绘制时自行裁剪。
      final blocks =
          json.decode(savedValue('widget_timeline_blocks') as String) as List;
      final firstBlock = blocks.first as Map<String, dynamic>;
      expect(firstBlock['s'], 120);
      expect(firstBlock['e'], 140);
      expect(firstBlock['l'], '深夜');
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
      expect(
          calls.where((call) => call.method == 'updateWidget'), hasLength(1));
    });

    test('非 Android 不碰通道', () async {
      await HomeWidgetService.updateAppearance('{"v":1}', supported: false);

      expect(calls, isEmpty);
    });
  });
}
