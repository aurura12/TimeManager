import 'package:flutter/material.dart';

class Category {
  final String name;
  final Color color;
  final List<String> subCategories;

  Category(
      {required this.name, required this.color, this.subCategories = const []});

  // 创建副本以支持修改操作
  Category copyWith({
    String? name,
    Color? color,
    List<String>? subCategories,
  }) {
    return Category(
      name: name ?? this.name,
      color: color ?? this.color,
      subCategories: subCategories ?? this.subCategories,
    );
  }
}
