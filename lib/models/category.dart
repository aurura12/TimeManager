import 'package:flutter/material.dart';

class Category {
  final String id;
  final String name;
  final Color color;
  final List<String> subCategories;
  final List<String> hiddenSubCategories;

  Category({
    String? id,
    required this.name,
    required this.color,
    this.subCategories = const [],
    this.hiddenSubCategories = const [],
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString();

  Category copyWith({
    String? id,
    String? name,
    Color? color,
    List<String>? subCategories,
    List<String>? hiddenSubCategories,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      subCategories: subCategories ?? this.subCategories,
      hiddenSubCategories: hiddenSubCategories ?? this.hiddenSubCategories,
    );
  }
}
