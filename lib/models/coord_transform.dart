import 'dart:math' as math;

/// WGS-84 → GCJ-02 坐标转换。
///
/// GPS 设备获取的是 WGS-84 坐标，高德地图使用 GCJ-02（国测局）坐标系，
/// 直接使用 GPS 坐标在 GCJ-02 瓦片上会产生 300-500 米的偏移。
///
/// 算法来源：https://github.com/wandergis/coordTransform
class CoordTransform {
  static const double _a = 6378245.0;
  static const double _ee = 0.00669342162296594323;
  static const double _xPi = math.pi * 3000.0 / 180.0;

  /// 将 WGS-84 (纬度, 经度) 转换为 GCJ-02。
  static (double lat, double lng) wgs84ToGcj02(double lat, double lng) {
    if (_outOfChina(lat, lng)) return (lat, lng);
    final dLat = _transformLat(lng - 105.0, lat - 35.0);
    final dLng = _transformLng(lng - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    final resultLat = lat + (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
    final resultLng = lng + (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
    return (resultLat, resultLng);
  }

  static double _transformLat(double x, double y) {
    var ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320.0 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0;
    return ret;
  }

  static double _transformLng(double x, double y) {
    var ret = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0;
    return ret;
  }

  /// 判断坐标是否在中国境外（境外不需要转换）。
  static bool _outOfChina(double lat, double lng) {
    return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
  }
}
