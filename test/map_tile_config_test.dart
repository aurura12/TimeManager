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
}
