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
          categories.add(Category.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v))));
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
  return json.encode({
    'updated_at': nowMs,
    'categories': doc.categories.map((c) => c.toJson()).toList(),
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
  final deleted = <String, int>{};
  deleted.addAll(local.deletedCategories);
  for (final entry in remote.deletedCategories.entries) {
    final existing = deleted[entry.key];
    if (existing == null || entry.value > existing) {
      deleted[entry.key] = entry.value;
    }
  }

  final byId = <String, Category>{};
  for (final c in local.categories) {
    byId[c.id] = c;
  }
  for (final c in remote.categories) {
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
  final baseOrder = local.updatedAt >= remote.updatedAt ? local : remote;
  final otherOrder = baseOrder == local ? remote : local;

  final merged = <Category>[];
  final seen = <String>{};
  for (final c in baseOrder.categories) {
    if (surviving.containsKey(c.id) && seen.add(c.id)) {
      merged.add(surviving[c.id]!);
    }
  }
  for (final c in otherOrder.categories) {
    if (surviving.containsKey(c.id) && seen.add(c.id)) {
      merged.add(surviving[c.id]!);
    }
  }

  return CategoryDocument(
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    categories: merged,
    deletedCategories: deleted,
  );
}
