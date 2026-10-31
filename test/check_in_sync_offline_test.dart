import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/services/check_in_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });
  tearDown(() {
    AppIdentityService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  test('没有 Token 时拉取和推送都返回离线，而不是失败', () async {
    // 同步中心据此把模块报成「离线待恢复」，用户没配 Token 不该亮红点。
    final service = CheckInSyncService(tokenLoader: () async => null);

    final pull = await service.pullFromGitHub();
    expect(pull.success, isFalse);
    expect(pull.offline, isTrue);
    expect(pull.error, contains('Token'));

    final push = await service.pushToGitHub();
    expect(push.success, isFalse);
    expect(push.offline, isTrue);
  });

  test('普通失败不会被标成离线', () {
    expect(CheckInSyncResult.fail('本地保存失败').offline, isFalse);
    expect(CheckInSyncResult.offline('未配置当前平台同步 Token').offline, isTrue);
  });
}
