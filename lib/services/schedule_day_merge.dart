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

  /// 解析/校验失败原因；为 null 表示内容可正常处理。
  final String? error;

  const ScheduleDayMergeResult({
    required this.slots,
    required this.updatedAt,
    this.error,
  });

  /// 内容是否合法（空内容也算合法，表示"无远端日程"）。
  bool get isValid => error == null;
}

/// 严格校验一天的槽位记录列表。
///
/// 返回 null 表示全部合法，否则返回中文错误描述。规则与覆盖拉取
/// (schedule_overwrite.dart) 保持一致，作为普通拉取、推送、覆盖拉取的统一校验器：
/// - 每条必须是对象，`i` 必须是 int 且 0..143 且不重复；
/// - `del`/`fc` 键出现时必须是 bool，`cid`/`eid` 必须是 String，`c`/`ts` 必须是 num；
/// - 携带 `l` 键但值不是 String 即非法（含 `l:null`）；
/// - live 条目（`del != true`）必须有非空 String 标签 `l`。
String? scheduleDayEntriesError(List<dynamic> rawSlots) {
  final indexes = <int>{};
  var position = 0;
  for (final raw in rawSlots) {
    if (raw is! Map) return '第 $position 条日程记录不是对象';
    final slot = Map<String, dynamic>.from(raw);
    final index = slot['i'];
    if (index is! int || index < 0 || index > 143 || !indexes.add(index)) {
      return '槽位索引非法或重复：$index';
    }
    final deleted = slot['del'];
    for (final key in const ['fc', 'del']) {
      if (slot.containsKey(key) && slot[key] is! bool) {
        return '第 $index 槽字段 $key 必须是布尔值';
      }
    }
    if (slot.containsKey('l') && slot['l'] is! String) {
      return '第 $index 槽标签字段类型非法';
    }
    if (deleted != true &&
        (slot['l'] is! String || (slot['l'] as String).isEmpty)) {
      return '第 $index 槽是有效日程但缺少非空标签';
    }
    for (final key in const ['cid', 'eid']) {
      if (slot.containsKey(key) && slot[key] is! String) {
        return '第 $index 槽字段 $key 必须是字符串';
      }
    }
    for (final key in const ['c', 'ts']) {
      if (slot.containsKey(key) && slot[key] is! num) {
        return '第 $index 槽字段 $key 必须是数字';
      }
    }
    position++;
  }
  return null;
}

/// 解析远端日程文件内容（新对象格式优先，旧裸数组回退）。
///
/// 与旧行为不同：只有"文件为空"表示无远端数据；JSON 解析失败、结构非法
/// 或任一槽位记录不通过 [scheduleDayEntriesError] 都会返回带 [error] 的
/// 非法结果，调用方必须据此中止合并/推送，不能静默当作"远端为空"。
ScheduleDayMergeResult parseScheduleContent(String? content) {
  if (content == null || content.trim().isEmpty) {
    return const ScheduleDayMergeResult(slots: [], updatedAt: 0);
  }
  dynamic decoded;
  try {
    decoded = json.decode(content);
  } catch (_) {
    return ScheduleDayMergeResult(
      slots: const [],
      updatedAt: 0,
      error: '内容不是合法 JSON',
    );
  }
  int updatedAt = 0;
  List<dynamic> rawSlots;
  if (decoded is Map) {
    updatedAt = _toInt(decoded['updated_at']) ?? 0;
    final raw = decoded['slots'];
    if (raw is List) {
      rawSlots = raw;
    } else {
      return ScheduleDayMergeResult(
        slots: const [],
        updatedAt: 0,
        error: '缺少有效的 slots 数组字段',
      );
    }
  } else if (decoded is List) {
    // 旧裸数组格式：无时间信息，视为最旧
    rawSlots = decoded;
  } else {
    return ScheduleDayMergeResult(
      slots: const [],
      updatedAt: 0,
      error: '内容结构非法（应为对象或数组）',
    );
  }
  final entryError = scheduleDayEntriesError(rawSlots);
  if (entryError != null) {
    return ScheduleDayMergeResult(
      slots: const [],
      updatedAt: 0,
      error: entryError,
    );
  }
  final slots = rawSlots
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList();
  return ScheduleDayMergeResult(slots: slots, updatedAt: updatedAt);
}

/// 合并本地与远端槽位（后写覆盖）。
///
/// - 两侧都有同一槽位：`ts` 大者胜，平局取本地；
/// - 仅一侧有：保留该侧（union）。tombstone（`del: true`）与 live entry
///   都携带 `ts`，通常与普通槽位一样参与"大者胜"比较；
/// - Google 来源墓碑（`del: true, fc: true`）只能删除 Google live entry，
///   不能覆盖个人 live entry；
/// - 旧版未携带 `fc` 的墓碑无法可靠判定来源，继续按普通墓碑处理；
/// - 若一侧 entry 缺失另一侧不存在，则不产生任何 entry（该槽保持空）。
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
      // Google 导入删除只清理 Google 副本，不得覆盖另一端的个人日程。
      if (_isCalendarTombstone(local) && _isPersonalLiveEntry(remote)) {
        merged.add(remote);
      } else if (_isCalendarTombstone(remote) && _isPersonalLiveEntry(local)) {
        merged.add(local);
      } else {
        // 其余冲突：后写者胜
        merged.add(_tsOf(local) >= _tsOf(remote) ? local : remote);
      }
    } else if (local != null) {
      merged.add(local);
    } else if (remote != null) {
      merged.add(remote);
    }
  }
  merged.sort((a, b) => _indexOf(a).compareTo(_indexOf(b)));
  return merged;
}

/// 生成一次推送应写入远端的槽位。
///
/// 非空数据仍采用双向合并，避免不同设备各自新增的槽位互相覆盖；
/// 空数据表示用户明确清空了当天日程，必须保留为空，不能再把远端旧记录合并回来。
List<Map<String, dynamic>> scheduleEntriesForPush({
  required List<Map<String, dynamic>> localEntries,
  required List<Map<String, dynamic>> remoteEntries,
}) {
  if (localEntries.isEmpty) return <Map<String, dynamic>>[];
  return mergeScheduleSlots(
    localEntries: localEntries,
    remoteEntries: remoteEntries,
  );
}

int _indexOf(Map<String, dynamic> e) => (e['i'] as num?)?.toInt() ?? -1;

int _tsOf(Map<String, dynamic> e) => (e['ts'] as num?)?.toInt() ?? 0;

bool _isCalendarTombstone(Map<String, dynamic> e) =>
    e['del'] == true && e['fc'] == true;

bool _isPersonalLiveEntry(Map<String, dynamic> e) =>
    e['del'] != true && e['fc'] != true;

/// 是否为删除墓碑 entry（`{i, del: true, ts}`）
bool isTombstoneEntry(Map<String, dynamic> e) => e['del'] == true;

int? _toInt(dynamic v) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '');
}
