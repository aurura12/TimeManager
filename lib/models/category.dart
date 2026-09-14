import 'package:flutter/material.dart';
import '../theme/app_semantic_colors.dart';

class Category {
  final String id;
  final String name;
  final Color color;
  final List<String> subCategories;
  final List<String> hiddenSubCategories;

  /// 分类最后修改时间（毫秒时间戳），用于跨端合并冲突判断。
  /// 旧数据缺省为 0，首次加载时统一迁移为当前时间。
  final int updatedAt;

  Category({
    String? id,
    required this.name,
    required this.color,
    this.subCategories = const [],
    this.hiddenSubCategories = const [],
    this.updatedAt = 0,
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString();

  Category copyWith({
    String? id,
    String? name,
    Color? color,
    List<String>? subCategories,
    List<String>? hiddenSubCategories,
    int? updatedAt,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      subCategories: subCategories ?? this.subCategories,
      hiddenSubCategories: hiddenSubCategories ?? this.hiddenSubCategories,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'color': color.toARGB32(),
      'subCategories': subCategories,
      'hiddenSubCategories': hiddenSubCategories,
      'updatedAt': updatedAt,
    };
  }

  factory Category.fromJson(Map<String, dynamic> map) {
    return Category(
      id: _asString(map['id']),
      name: _asString(map['name']) ?? '',
      // 历史数据里可能存过半透明色（十六进制输入框曾接受 8 位 ARGB），
      // 这里统一收成不透明，否则时间块底色会跟着半透明。
      color: AppSemanticColors.opaque(Color(_asInt(map['color']) ??
          AppSemanticColors.neutral.toARGB32())),
      subCategories: _asStringList(map['subCategories']),
      hiddenSubCategories: _asStringList(map['hiddenSubCategories']),
      updatedAt: _asInt(map['updatedAt']) ?? 0,
    );
  }

  static num? _asNum(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value.trim());
    return null;
  }

  static int? _asInt(dynamic value) => _asNum(value)?.toInt();

  static String? _asString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }

  /// 只取列表里的字符串项，忽略 null / 数字等非法项，避免整条分类解析失败。
  static List<String> _asStringList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<String>().toList();
  }
}
