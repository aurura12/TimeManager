import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'transactional_preference_string.dart';

/// 菜单栏面板「上次写入的分类 / 子事件」。
///
/// 本机偏好，独立于身份、不进同步与备份。存一份分类名是刻意的冗余：
/// 换身份 / 同步合并后分类 id 可能重建，名字是第二道兜底。
@immutable
class MenuBarTarget {
  const MenuBarTarget({
    required this.categoryId,
    this.categoryName,
    this.subLabel,
  });

  final String categoryId;
  final String? categoryName;
  final String? subLabel;

  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'categoryId': categoryId,
        'categoryName': categoryName,
        'subLabel': subLabel,
      };

  /// 脏数据一律返回 null：它只影响「记不记得上次目标」，不能影响写入。
  static MenuBarTarget? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['categoryId'];
    if (id is! String || id.isEmpty) return null;
    final name = raw['categoryName'];
    final sub = raw['subLabel'];
    return MenuBarTarget(
      categoryId: id,
      categoryName: name is String && name.isNotEmpty ? name : null,
      subLabel: sub is String && sub.isNotEmpty ? sub : null,
    );
  }
}

/// 读写菜单栏面板上次的目标（单键 JSON，原子写入）。
class MenuBarTargetStore {
  MenuBarTargetStore({TransactionalPreferenceString? preference})
      : _preference = preference ?? TransactionalPreferenceString(storageKey);

  static const String storageKey = 'app_menu_bar_target_v1';

  final TransactionalPreferenceString _preference;

  Future<MenuBarTarget?> load() async {
    try {
      final raw = await _preference.load();
      if (raw == null || raw.isEmpty) return null;
      return MenuBarTarget.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<bool> save(MenuBarTarget target) async {
    try {
      return await _preference.save(jsonEncode(target.toJson()));
    } on Object {
      return false;
    }
  }
}
