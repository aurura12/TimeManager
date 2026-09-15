import 'package:flutter_test/flutter_test.dart';

import 'package:time_manager/services/home_widget_service.dart';

void main() {
  group('HomeWidgetService.parseActionUri', () {
    test('生成的动作 URI 都能严格往返解析', () {
      for (final action in [
        HomeWidgetAction.todayRecords,
      ]) {
        final uri = HomeWidgetService.actionUri(action);
        final request = HomeWidgetService.parseActionUri(uri);

        expect(request, isNotNull);
        expect(request!.action, action);
        expect(request.routeName, startsWith('/widget/'));
      }
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
}
