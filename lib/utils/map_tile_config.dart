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

  /// 地图服务 attribution。瓦片源保持不变，服务标识统一从这里读取。
  static const attributionSource = '高德地图';

  /// 地图瓦片请求的隐私说明。
  ///
  /// 这里只说明本组件发起的瓦片请求，不把它扩大解释成应用整体的隐私政策。
  static const privacyNotice =
      '加载地图瓦片时，地图服务商可能收到请求所需的网络信息（例如 IP、请求时间）以及地图视野对应的瓦片坐标。打卡文本和照片不会作为瓦片请求参数发送。';

  /// 至少收集到这么多张失败瓦片后才触发自动恢复，避免单张边缘瓦片抖动造成反复刷新。
  static const automaticRetryFailureThreshold = 2;

  /// 自动恢复只执行有限次数；用户点击“重试地图”后可以重新开始这一轮。
  static const automaticRetryDelays = <Duration>[
    Duration(milliseconds: 600),
    Duration(seconds: 2),
  ];

  static const maxAutomaticRetries = 2;

  /// 等待一小段时间合并同一批瓦片的错误回调，避免每张瓦片都刷新 UI。
  static const failureDisplayDelay = Duration(milliseconds: 400);

  /// 重试后在没有再次收到错误时，认为地图已恢复的观察窗口。
  static const retryRecoveryWindow = Duration(seconds: 3);
}

/// 对瓦片错误进行去重，并限制自动重试次数。
///
/// 这个类不依赖 Flutter widget，便于测试重试边界，也避免把“每张瓦片回调一次”
/// 直接映射成“每张瓦片弹一次提示”。
class MapTileFailureMonitor {
  MapTileFailureMonitor({
    int automaticRetryFailureThreshold =
        MapTileConfig.automaticRetryFailureThreshold,
    int maxAutomaticRetries = MapTileConfig.maxAutomaticRetries,
  })  : _automaticRetryFailureThreshold = automaticRetryFailureThreshold,
        _maxAutomaticRetries = maxAutomaticRetries;

  final int _automaticRetryFailureThreshold;
  final int _maxAutomaticRetries;
  final Set<String> _failedTileKeys = <String>{};

  int automaticRetryCount = 0;

  int get failedTileCount => _failedTileKeys.length;

  bool get hasFailures => _failedTileKeys.isNotEmpty;

  bool get shouldAutomaticallyRetry =>
      failedTileCount >= _automaticRetryFailureThreshold &&
      automaticRetryCount < _maxAutomaticRetries;

  Duration get nextAutomaticRetryDelay {
    if (MapTileConfig.automaticRetryDelays.isEmpty) return Duration.zero;
    final index =
        automaticRetryCount < MapTileConfig.automaticRetryDelays.length
            ? automaticRetryCount
            : MapTileConfig.automaticRetryDelays.length - 1;
    return MapTileConfig.automaticRetryDelays[index];
  }

  /// 返回 true 表示这是本轮第一次看到该瓦片的错误。
  bool recordFailure(String tileKey) => _failedTileKeys.add(tileKey);

  bool beginAutomaticRetry() {
    if (!shouldAutomaticallyRetry) return false;
    automaticRetryCount++;
    _failedTileKeys.clear();
    return true;
  }

  void beginManualRetry() {
    automaticRetryCount = 0;
    _failedTileKeys.clear();
  }

  void clearFailures() => _failedTileKeys.clear();
}
