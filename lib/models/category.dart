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
      id: map['id'] as String?,
      name: map['name'] as String? ?? '',
      // 历史数据里可能存过半透明色（十六进制输入框曾接受 8 位 ARGB），
      // 这里统一收成不透明，否则时间块底色会跟着半透明。
      color: AppSemanticColors.opaque(Color((map['color'] as num?)?.toInt() ??
          AppSemanticColors.neutral.toARGB32())),
      subCategories:
          map['subCategories'] is List ? List<String>.from(map['subCategories'] as List) : const [],
      hiddenSubCategories: map['hiddenSubCategories'] is List
          ? List<String>.from(map['hiddenSubCategories'] as List)
          : const [],
      updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}
