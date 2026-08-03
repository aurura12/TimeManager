import 'time_provider.dart';

/// 目标统计数据缓存
/// 缓存 _getTargetCountOnDate 和 getTimePointStatus 的计算结果
class TargetStatsCache {
  // 缓存 key: "${targetId}_${dateKey}"
  final Map<String, double> _completionCounts = {};
  final Map<String, TimePointStatus> _timePointStatuses = {};

  /// 数据版本号：任何失效操作都会递增。
  /// 供 UI 层判断"目标统计数据是否已变化"，从而决定是否复用计算结果。
  int revision = 0;

  /// 获取缓存的目标完成次数
  double? getCachedCount(String targetId, String dateKey) {
    return _completionCounts['${targetId}_$dateKey'];
  }

  /// 缓存目标完成次数
  void cacheCount(String targetId, String dateKey, double count) {
    _completionCounts['${targetId}_$dateKey'] = count;
  }

  /// 获取缓存的时间点状态
  TimePointStatus? getCachedTimePointStatus(String targetId, String dateKey) {
    return _timePointStatuses['${targetId}_$dateKey'];
  }

  /// 缓存时间点状态
  void cacheTimePointStatus(String targetId, String dateKey, TimePointStatus status) {
    _timePointStatuses['${targetId}_$dateKey'] = status;
  }

  /// 全量失效缓存
  void invalidate() {
    revision++;
    _completionCounts.clear();
    _timePointStatuses.clear();
  }

  /// 单日期失效缓存
  void invalidateDate(String dateKey) {
    revision++;
    _completionCounts.removeWhere((key, _) => key.endsWith('_$dateKey'));
    _timePointStatuses.removeWhere((key, _) => key.endsWith('_$dateKey'));
  }
}
