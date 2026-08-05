import 'dart:convert';

/// 日程单日文件的解析与合并（后写覆盖）。
///
/// 新格式：`{ "updated_at": ms, "slots": [{ "i":0, "l":"...", "c":123, "ts": ms }] }`
/// 旧格式：裸数组 `[{ "i":0, "l":"...", "c":123 }]`（视为 updated_at=0、槽位 ts=0）
class ScheduleDayMergeResult {
  /// 合并后的槽位 entries（含 `i`/`ts` 字段）
  final List<Map<String, dynamic>> slots;

  /// 文件级最后修改时间（epoch ms）
  final int updatedAt;

  const ScheduleDayMergeResult({required this.slots, required this.updatedAt});
}

/// 解析远端日程文件内容（新对象格式优先，旧裸数组回退）。
/// 解析失败视为无远端数据。
ScheduleDayMergeResult parseScheduleContent(String? content) {
  if (content == null || content.trim().isEmpty) {
    return const ScheduleDayMergeResult(slots: [], updatedAt: 0);
  }
  dynamic decoded;
  try {
    decoded = json.decode(content);
  } catch (_) {
    return const ScheduleDayMergeResult(slots: [], updatedAt: 0);
  }
  if (decoded is Map) {
    final updatedAt = _toInt(decoded['updated_at']) ?? 0;
    final raw = decoded['slots'];
    final slots = raw is List
        ? raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : <Map<String, dynamic>>[];
    return ScheduleDayMergeResult(slots: slots, updatedAt: updatedAt);
  }
  if (decoded is List) {
    // 旧裸数组格式：无时间信息，视为最旧
    final slots = decoded
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    return ScheduleDayMergeResult(slots: slots, updatedAt: 0);
  }
  return const ScheduleDayMergeResult(slots: [], updatedAt: 0);
}

/// 合并本地与远端槽位（后写覆盖）。
///
/// - 两侧都有同一槽位：`ts` 大者胜，平局取本地；
/// - 仅一侧有：保留该侧（union）。不做"缺失推断删除"——因为文件级
///   时间戳无法区分"另一端删除了该槽"与"另一端从未编辑过该槽"，
///   用文件时间推断会把对方较早的记录误删。
///   删除的同步需要槽位级 tombstone，属后续增强。
List<Map<String, dynamic>> mergeScheduleSlots({
  required List<Map<String, dynamic>> localEntries,
  required List<Map<String, dynamic>> remoteEntries,
}) {
  final localByIndex = <int, Map<String, dynamic>>{
    for (final e in localEntries) _indexOf(e): e,
  };
  final remoteByIndex = <int, Map<String, dynamic>>{
    for (final e in remoteEntries) _indexOf(e): e,
  };

  final indexes = <int>{...localByIndex.keys, ...remoteByIndex.keys};
  final merged = <Map<String, dynamic>>[];
  for (final idx in indexes) {
    if (idx < 0) continue;
    final local = localByIndex[idx];
    final remote = remoteByIndex[idx];
    if (local != null && remote != null) {
      // 冲突：后写者胜
      merged.add(_tsOf(local) >= _tsOf(remote) ? local : remote);
    } else if (local != null) {
      merged.add(local);
    } else if (remote != null) {
      merged.add(remote);
    }
  }
  merged.sort((a, b) => _indexOf(a).compareTo(_indexOf(b)));
  return merged;
}

int _indexOf(Map<String, dynamic> e) => (e['i'] as num?)?.toInt() ?? -1;

int _tsOf(Map<String, dynamic> e) => (e['ts'] as num?)?.toInt() ?? 0;

int? _toInt(dynamic v) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '');
}
