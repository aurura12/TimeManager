import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/map_tile_config.dart';

void main() {
  test('保留当前地图源及其请求参数', () {
    expect(
      MapTileConfig.urlTemplate,
      'https://webrd{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
    );
    expect(MapTileConfig.subdomains, ['01', '02', '03', '04']);
    expect(
      MapTileConfig.userAgentPackageName,
      'com.example.time_manager',
    );
  });

  test('地图服务标识、隐私说明和有限重试策略集中且稳定', () {
    expect(MapTileConfig.attributionSource, '高德地图');
    expect(MapTileConfig.privacyNotice, contains('地图瓦片'));
    expect(MapTileConfig.privacyNotice, contains('照片'));
    expect(MapTileConfig.maxAutomaticRetries, 2);
    expect(
      MapTileConfig.automaticRetryDelays.length,
      MapTileConfig.maxAutomaticRetries,
    );
  });

  test('地图缩放范围限制在瓦片服务提供的层级内', () {
    expect(MapTileConfig.minZoom, lessThan(MapTileConfig.maxZoom));
    // 预览组件的初始 zoom 只取 9 / 11 / 13 / 15，必须全部落在限制区间内，
    // 否则一打开地图就会请求服务端不提供的层级。
    expect(MapTileConfig.minZoom, lessThanOrEqualTo(9.0));
    expect(MapTileConfig.maxZoom, greaterThanOrEqualTo(15.0));
  });

  test('失败瓦片按坐标去重，自动重试有上限，手动重试可重新开始', () {
    final monitor = MapTileFailureMonitor();

    expect(monitor.recordFailure('15/1/2'), isTrue);
    expect(monitor.recordFailure('15/1/2'), isFalse);
    expect(monitor.failedTileCount, 1);
    expect(monitor.shouldAutomaticallyRetry, isFalse);

    expect(monitor.recordFailure('15/1/3'), isTrue);
    expect(monitor.shouldAutomaticallyRetry, isTrue);

    expect(monitor.beginAutomaticRetry(), isTrue);
    expect(monitor.automaticRetryCount, 1);
    expect(monitor.failedTileCount, 0);

    monitor.recordFailure('15/1/2');
    monitor.recordFailure('15/1/3');
    expect(monitor.beginAutomaticRetry(), isTrue);
    expect(monitor.automaticRetryCount, 2);

    monitor.recordFailure('15/1/2');
    monitor.recordFailure('15/1/3');
    expect(monitor.shouldAutomaticallyRetry, isFalse);
    expect(monitor.beginAutomaticRetry(), isFalse);

    monitor.beginManualRetry();
    expect(monitor.automaticRetryCount, 0);
    expect(monitor.failedTileCount, 0);
    expect(monitor.shouldAutomaticallyRetry, isFalse);
  });
}
