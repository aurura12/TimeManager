/// 地图瓦片配置。
///
/// 地图页面只依赖这些配置项，后续更换瓦片服务时不需要修改页面逻辑。
/// 当前地址保持现有高德瓦片地址不变。
class MapTileConfig {
  const MapTileConfig._();

  static const urlTemplate =
      'https://webrd{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}';

  static const subdomains = <String>['01', '02', '03', '04'];

  static const userAgentPackageName = 'com.example.time_manager';
}
