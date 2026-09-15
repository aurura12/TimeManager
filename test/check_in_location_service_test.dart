import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/services/check_in_location_service.dart';

void main() {
  tearDown(() {
    CheckInLocationService.settingsLauncherForTesting = null;
    CheckInLocationService.locationLoaderForTesting = null;
  });

  test('可注入系统设置启动器，不触发真实系统调用', () async {
    var launchCount = 0;
    CheckInLocationService.settingsLauncherForTesting = () async {
      launchCount++;
      return true;
    };

    expect(await CheckInLocationService.openAppSettings(), isTrue);
    expect(launchCount, 1);
  });

  test('系统设置启动失败时返回 false', () async {
    CheckInLocationService.settingsLauncherForTesting = () async {
      throw StateError('test failure');
    };

    expect(await CheckInLocationService.openAppSettings(), isFalse);
  });

  test('永久拒绝状态会暴露给 UI 恢复流程', () async {
    CheckInLocationService.locationLoaderForTesting = () async {
      return const CheckInLocationAccessResult(
        permissionStatus: CheckInLocationPermissionStatus.deniedForever,
      );
    };

    final result = await CheckInLocationService.getCurrentLocationWithStatus();

    expect(result.isPermanentlyDenied, isTrue);
    expect(result.location, isNull);
  });
}
