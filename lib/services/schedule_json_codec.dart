import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 只把脏日期的快照传入后台；历史 JSON 在同一次后台任务中解码、合并和编码。
class ScheduleJsonPatch {
  const ScheduleJsonPatch({
    required this.existingJson,
    required this.changedDays,
  });

  final String? existingJson;
  final Map<String, List<Map<String, dynamic>>> changedDays;
}

String encodeScheduleJsonPatch(ScheduleJsonPatch patch) {
  final root = patch.existingJson == null
      ? <String, dynamic>{}
      : json.decode(patch.existingJson!) as Map<String, dynamic>;
  for (final entry in patch.changedDays.entries) {
    if (entry.value.isEmpty) {
      root.remove(entry.key);
    } else {
      root[entry.key] = entry.value;
    }
  }
  // 损坏的历史不能当作空数据写回；异常由保存入口记录，脏标记留待重试。
  return json.encode(root);
}

class _ScheduleJsonReadRequest {
  const _ScheduleJsonReadRequest(this.raw, this.dateKeys, this.maxDays);

  final String raw;
  final Set<String>? dateKeys;
  final int? maxDays;
}

/// 一次解码、多处复用；只返回所需日期，避免把整份历史对象复制回 UI isolate。
Future<Map<String, dynamic>?> readScheduleJsonDays(
  String? raw, {
  Set<String>? dateKeys,
  int? maxDays,
}) {
  if (raw == null || raw.isEmpty) return Future.value(null);
  return compute(
    _decodeSelectedScheduleDays,
    _ScheduleJsonReadRequest(raw, dateKeys, maxDays),
  );
}

Map<String, dynamic>? _decodeSelectedScheduleDays(
  _ScheduleJsonReadRequest request,
) {
  try {
    final root = json.decode(request.raw) as Map<String, dynamic>?;
    if (root == null) return <String, dynamic>{};
    final dates = request.dateKeys;
    if (dates != null) {
      return {
        for (final key in dates)
          if (root.containsKey(key)) key: root[key],
      };
    }
    return Map.fromEntries(root.entries.take(request.maxDays ?? root.length));
  } catch (_) {
    return null;
  }
}
