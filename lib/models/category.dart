import 'package:flutter/material.dart';

class Category {
  final String name;
  final Color color;
  final List<String> subCategories;

  Category(
      {required this.name, required this.color, this.subCategories = const []});
}
