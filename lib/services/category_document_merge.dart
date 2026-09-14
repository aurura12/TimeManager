import 'dart:convert';

import '../models/category.dart';

/// 一份分类同步文档。
///
/// 对应 Gitee 上 `categories/{userCode}.json` 的内容：
/// ```json
/// {
///   "updated_at": 1710000000000,
///   "categories": [{ "id": "...", "name": "...", "color": 4293388906,
///                    "subCategories": [], "hiddenSubCategories": [],
///                    "updatedAt": 1710000000000 }],
///   "deletedCategories": { "id": 1710000000000 }
/// }
/// ```
class CategoryDocument {
  /// 文档最后修改时间（毫秒时间戳），用于合并时的顺序基准。
  final int updatedAt;

  /// 有序分类列表。
  final List<Category> categories;

  /// 删除墓碑：分类 id → 删除时间（毫秒时间戳）。
  final Map<String, int> deletedCategories;

  const CategoryDocument({
    this.updatedAt = 0,
    this.categories = const [],
    this.deletedCategories = const {},
  });
}

/// 分类写入前的规范化结果。
///
/// `idRemap` 用于把因同名合并而被丢弃的旧分类 ID 迁移到胜出的分类，
/// 避免时间块、目标或模板留下悬空引用。
class CategoryNormalizationResult {
  final List<Category> categories;
  final Map<String, String> idRemap;
  final bool changed;

  const CategoryNormalizationResult({
    required this.categories,
    required this.idRemap,
    required this.changed,
  });
}

/// 与 UI 校验保持一致的分类显示名称比较键。
String categoryLabelKey(String value) => value.trim().toLowerCase();

/// 只裁剪名称，不改变列表长度和顺序。
Category trimCategoryForStorage(Category category) {
  return category.copyWith(
    name: category.name.trim(),
    subCategories: category.subCategories.map((value) => value.trim()).toList(),
    hiddenSubCategories:
        category.hiddenSubCategories.map((value) => value.trim()).toList(),
  );
}

List<String> _dedupeSubCategories(
  List<String> values,
  Set<String> seen,
) {
  final result = <String>[];
  for (final value in values) {
    final key = categoryLabelKey(value);
    if (seen.add(key)) result.add(value);
  }
  return result;
}

Category _canonicalizeCategory(Category category) {
  final normalized = trimCategoryForStorage(category);
  final seen = <String>{};
  final visible = _dedupeSubCategories(normalized.subCategories, seen);
  final hidden = _dedupeSubCategories(normalized.hiddenSubCategories, seen);
  return normalized.copyWith(
    subCategories: visible,
    hiddenSubCategories: hidden,
  );
}

bool _categoryEquals(Category left, Category right) {
  if (left.id != right.id ||
      left.name != right.name ||
      left.color != right.color ||
      left.updatedAt != right.updatedAt ||
      left.subCategories.length != right.subCategories.length ||
      left.hiddenSubCategories.length != right.hiddenSubCategories.length) {
    return false;
  }
  for (var i = 0; i < left.subCategories.length; i++) {
    if (left.subCategories[i] != right.subCategories[i]) return false;
  }
  for (var i = 0; i < left.hiddenSubCategories.length; i++) {
    if (left.hiddenSubCategories[i] != right.hiddenSubCategories[i]) {
      return false;
    }
  }
  return true;
}

/// 规范化分类名称/子事件，并按 ID、再按父事件显示名称去重。
///
/// 同名分类保留 `updatedAt` 较新的版本；时间戳相同时保留先出现的版本，
/// 保证结果稳定且保留原有列表顺序。可见子事件优先于隐藏子事件。
CategoryNormalizationResult normalizeCategoriesForStorage(
  Iterable<Category> source,
) {
  final original = source.toList(growable: false);
  final normalized = original.map(_canonicalizeCategory).toList();

  // 先处理同 ID 的重复项。空 ID 交给 TimeProvider 的 ID 迁移逻辑，不能
  // 把所有空 ID 错误地视为同一个分类。
  final byId = <String, int>{};
  final byIdCategories = <Category>[];
  for (final category in normalized) {
    final existingIndex = category.id.isEmpty ? null : byId[category.id];
    if (existingIndex == null) {
      if (category.id.isNotEmpty) byId[category.id] = byIdCategories.length;
      byIdCategories.add(category);
      continue;
    }
    final existing = byIdCategories[existingIndex];
    if (category.updatedAt > existing.updatedAt) {
      byIdCategories[existingIndex] = category;
    }
  }

  final byName = <String, int>{};
  final categories = <Category>[];
  final idRemap = <String, String>{};
  for (final category in byIdCategories) {
    final nameKey = categoryLabelKey(category.name);
    final existingIndex = byName[nameKey];
    if (existingIndex == null || nameKey.isEmpty) {
      if (nameKey.isNotEmpty) byName[nameKey] = categories.length;
      categories.add(category);
      continue;
    }

    final existing = categories[existingIndex];
    final categoryWins = category.updatedAt > existing.updatedAt;
    final winner = categoryWins ? category : existing;
    final loser = categoryWins ? existing : category;
    // 空 ID 是历史遗留数据，不是稳定身份。保留较新的载荷，但借用另一侧
    // 的非空 ID，确保重映射不会把已有引用改成空串。
    final winnerId = winner.id.isNotEmpty
        ? winner.id
        : (loser.id.isNotEmpty ? loser.id : '');
    final normalizedWinner =
        winner.id == winnerId ? winner : winner.copyWith(id: winnerId);

    if (categoryWins) {
      if (existing.id.isNotEmpty && existing.id != normalizedWinner.id) {
        idRemap[existing.id] = normalizedWinner.id;
      }
    } else {
      if (category.id.isNotEmpty && category.id != normalizedWinner.id) {
        idRemap[category.id] = normalizedWinner.id;
      }
    }
    categories[existingIndex] = normalizedWinner;
  }

  // 解析可能形成 A→B、B→C 的链，统一压缩成直接映射。
  final resolvedRemap = <String, String>{};
  String resolve(String id) {
    var current = id;
    final visited = <String>{};
    while (visited.add(current) && idRemap.containsKey(current)) {
      current = idRemap[current]!;
    }
    return current;
  }

  for (final id in idRemap.keys) {
    final target = resolve(id);
    if (id != target) resolvedRemap[id] = target;
  }

  final changed = original.length != categories.length ||
      original.length != byIdCategories.length ||
      original.asMap().entries.any(
            (entry) =>
                entry.key >= categories.length ||
                !_categoryEquals(entry.value, categories[entry.key]),
          );

  return CategoryNormalizationResult(
    categories: List.unmodifiable(categories),
    idRemap: Map.unmodifiable(resolvedRemap),
    changed: changed || resolvedRemap.isNotEmpty,
  );
}

/// 解析分类同步文档；失败或空返回空文档（updatedAt=0）。
CategoryDocument parseCategoryDocument(String? content) {
  if (content == null || content.trim().isEmpty) {
    return const CategoryDocument();
  }
  try {
    final data = json.decode(content) as Map<String, dynamic>;
    final categories = <Category>[];
    final rawCategories = data['categories'];
    if (rawCategories is List) {
      for (final item in rawCategories) {
        if (item is Map<String, dynamic>) {
          categories.add(Category.fromJson(item));
        } else if (item is Map) {
          categories.add(
              Category.fromJson(item.map((k, v) => MapEntry(k.toString(), v))));
        }
      }
    }
    final deleted = <String, int>{};
    final rawDeleted = data['deletedCategories'];
    if (rawDeleted is Map) {
      rawDeleted.forEach((k, v) {
        final ts = (v is num) ? v.toInt() : int.tryParse(v.toString());
        if (k is String && ts != null && ts > 0) {
          deleted[k] = ts;
        }
      });
    }
    return CategoryDocument(
      updatedAt: (data['updated_at'] as num?)?.toInt() ?? 0,
      categories: categories,
      deletedCategories: deleted,
    );
  } catch (_) {
    return const CategoryDocument();
  }
}

/// 序列化分类同步文档为 JSON 字符串。
String encodeCategoryDocument(CategoryDocument doc, {required int nowMs}) {
  final categories = normalizeCategoriesForStorage(doc.categories).categories;
  return json.encode({
    'updated_at': nowMs,
    'categories': categories.map((c) => c.toJson()).toList(),
    'deletedCategories': doc.deletedCategories,
  });
}

/// 双向合并本地与远端分类文档。
///
/// 规则：
/// - 删除墓碑取两侧并集，同 id 取时间戳大者；
/// - 分类按 id union：仅一侧有的保留（除非墓碑时间更新则视为删除），
///   两侧都有的取 updatedAt 大者（平局取本地）；
/// - 删除与更新冲突：分类 updatedAt 与墓碑时间谁大谁胜；
/// - 顺序：以文档 updatedAt 大者一侧的顺序为基准，另一侧独有的分类按该侧相对顺序追加到尾部。
CategoryDocument mergeCategoryDocuments({
  required CategoryDocument local,
  required CategoryDocument remote,
}) {
  final localCategories =
      normalizeCategoriesForStorage(local.categories).categories;
  final remoteCategories =
      normalizeCategoriesForStorage(remote.categories).categories;

  final deleted = <String, int>{};
  deleted.addAll(local.deletedCategories);
  for (final entry in remote.deletedCategories.entries) {
    final existing = deleted[entry.key];
    if (existing == null || entry.value > existing) {
      deleted[entry.key] = entry.value;
    }
  }

  final byId = <String, Category>{};
  for (final c in localCategories) {
    if (c.id.isNotEmpty) byId[c.id] = c;
  }
  for (final c in remoteCategories) {
    if (c.id.isEmpty) continue;
    final localCat = byId[c.id];
    if (localCat == null || (c.updatedAt > localCat.updatedAt)) {
      byId[c.id] = c;
    }
  }

  // 墓碑时间 > 分类更新时间 → 视为删除，不复活。
  final surviving = <String, Category>{};
  byId.forEach((id, cat) {
    final tombstone = deleted[id];
    if (tombstone != null && tombstone > cat.updatedAt) {
      return; // 删除胜出
    }
    surviving[id] = cat;
  });

  // 顺序：文档 updatedAt 大者一侧为基准。
  final baseOrder =
      local.updatedAt >= remote.updatedAt ? localCategories : remoteCategories;
  final otherOrder =
      baseOrder == localCategories ? remoteCategories : localCategories;

  final merged = <Category>[];
  final seenIds = <String>{};
  for (final c in baseOrder) {
    if (c.id.isEmpty) {
      // 空 ID 没有可用于合并的身份；保留每一条，交给最终按名称规范化。
      merged.add(c);
    } else if (surviving.containsKey(c.id) && seenIds.add(c.id)) {
      merged.add(surviving[c.id]!);
    }
  }
  for (final c in otherOrder) {
    if (c.id.isEmpty) {
      merged.add(c);
    } else if (surviving.containsKey(c.id) && seenIds.add(c.id)) {
      merged.add(surviving[c.id]!);
    }
  }

  final normalizedMerged = normalizeCategoriesForStorage(merged);
  return CategoryDocument(
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    categories: normalizedMerged.categories,
    deletedCategories: deleted,
  );
}
