import 'dart:convert';

import '../models/target.dart';

/// 一份目标同步文档，对应 Gitee 上的 `targets/{userCode}.json`。
class TargetDocument {
  /// 文档最后修改时间，用于传播目标列表排序。
  final int updatedAt;

  /// 有序目标列表。
  final List<Target> targets;

  /// 删除墓碑：目标 id → 删除时间戳（毫秒）。
  final Map<String, int> deletedTargets;

  /// 内容是否是可安全合并的目标文档。
  final bool isValid;

  const TargetDocument({
    this.updatedAt = 0,
    this.targets = const [],
    this.deletedTargets = const {},
    this.isValid = true,
  });
}

/// 解析目标同步文档；内容为空或格式损坏时返回空文档。
TargetDocument parseTargetDocument(String? content) {
  if (content == null || content.trim().isEmpty) {
    return const TargetDocument(isValid: false);
  }

  try {
    final data = json.decode(content) as Map<String, dynamic>;
    final targets = <Target>[];
    final rawTargets = data['targets'];
    if (rawTargets is List) {
      for (final item in rawTargets) {
        if (item is Map<String, dynamic>) {
          targets.add(Target.fromJson(item));
        } else if (item is Map) {
          targets.add(Target.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ));
        }
      }
    }

    final deletedTargets = <String, int>{};
    final rawDeletedTargets = data['deletedTargets'];
    if (rawDeletedTargets is Map) {
      rawDeletedTargets.forEach((key, value) {
        final timestamp =
            value is num ? value.toInt() : int.tryParse(value.toString());
        if (key is String && timestamp != null && timestamp > 0) {
          deletedTargets[key] = timestamp;
        }
      });
    }

    return TargetDocument(
      updatedAt: (data['updated_at'] as num?)?.toInt() ?? 0,
      targets: targets,
      deletedTargets: deletedTargets,
    );
  } catch (_) {
    return const TargetDocument(isValid: false);
  }
}

/// 将目标同步文档序列化为 JSON。
String encodeTargetDocument(TargetDocument doc, {required int nowMs}) {
  return json.encode({
    'updated_at': nowMs,
    'targets': doc.targets.map((target) => target.toJson()).toList(),
    'deletedTargets': doc.deletedTargets,
  });
}

/// 双向合并本地与远端目标文档。
TargetDocument mergeTargetDocuments({
  required TargetDocument local,
  required TargetDocument remote,
}) {
  final deletedTargets = <String, int>{};
  deletedTargets.addAll(local.deletedTargets);
  for (final entry in remote.deletedTargets.entries) {
    final existing = deletedTargets[entry.key];
    if (existing == null || entry.value > existing) {
      deletedTargets[entry.key] = entry.value;
    }
  }

  final byId = <String, Target>{};
  for (final target in local.targets) {
    byId[target.id] = target;
  }
  for (final target in remote.targets) {
    final localTarget = byId[target.id];
    if (localTarget == null || target.updatedAt > localTarget.updatedAt) {
      byId[target.id] = target;
    }
  }

  final surviving = <String, Target>{};
  byId.forEach((id, target) {
    final tombstone = deletedTargets[id];
    if (tombstone != null && tombstone > target.updatedAt) {
      return;
    }
    surviving[id] = target;
  });

  final baseOrder = local.updatedAt >= remote.updatedAt ? local : remote;
  final otherOrder = identical(baseOrder, local) ? remote : local;
  final merged = <Target>[];
  final seen = <String>{};
  for (final target in baseOrder.targets) {
    if (surviving.containsKey(target.id) && seen.add(target.id)) {
      merged.add(surviving[target.id]!);
    }
  }
  for (final target in otherOrder.targets) {
    if (surviving.containsKey(target.id) && seen.add(target.id)) {
      merged.add(surviving[target.id]!);
    }
  }

  return TargetDocument(
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    targets: merged,
    deletedTargets: deletedTargets,
  );
}
