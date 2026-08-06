import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_manager/models/category.dart';
import 'package:time_manager/services/category_document_merge.dart';

Category cat(String id, String name, int updatedAt,
    {List<String> subs = const []}) {
  return Category(
    id: id,
    name: name,
    color: const Color(0xFF9CB86A),
    subCategories: subs,
    updatedAt: updatedAt,
  );
}

void main() {
  test('同 ID 分类取 updatedAt 大者', () {
    final local = CategoryDocument(
        updatedAt: 100, categories: [cat('a', '本地', 200)]);
    final remote = CategoryDocument(
        updatedAt: 200, categories: [cat('a', '远端', 300)]);
    final merged = mergeCategoryDocuments(local: local, remote: remote);
    expect(merged.categories.length, 1);
    expect(merged.categories.first.name, '远端');
  });

  test('删除时间新于分类更新时间 → 删除生效不复活', () {
    final local = CategoryDocument(
        updatedAt: 100, categories: [cat('a', '本地', 200)]);
    final remote = CategoryDocument(
        updatedAt: 200, deletedCategories: {'a': 500});
    final merged = mergeCategoryDocuments(local: local, remote: remote);
    expect(merged.categories, isEmpty);
    expect(merged.deletedCategories['a'], 500);
  });

  test('分类更新时间新于删除时间 → 修改胜出（复活）', () {
    final local = CategoryDocument(
        updatedAt: 100, categories: [cat('a', '新改', 600)]);
    final remote = CategoryDocument(
        updatedAt: 200, deletedCategories: {'a': 500});
    final merged = mergeCategoryDocuments(local: local, remote: remote);
    expect(merged.categories.length, 1);
    expect(merged.categories.first.name, '新改');
  });

  test('两侧墓碑并集取时间戳大者，删除后不复活', () {
    final local = CategoryDocument(updatedAt: 100, deletedCategories: {'a': 500});
    final remote = CategoryDocument(
        updatedAt: 200,
        categories: [cat('a', '旧', 100)],
        deletedCategories: {'a': 400});
    final merged = mergeCategoryDocuments(local: local, remote: remote);
    expect(merged.categories, isEmpty);
    expect(merged.deletedCategories['a'], 500);
  });

  test('首次同步基线：本地独有分类保留、远端独有分类也加入', () {
    final local = CategoryDocument(
        updatedAt: 0, categories: [cat('local', '本地', 100)]);
    final remote = CategoryDocument(
        updatedAt: 0, categories: [cat('remote', '远端', 100)]);
    final merged = mergeCategoryDocuments(local: local, remote: remote);
    final ids = merged.categories.map((c) => c.id).toSet();
    expect(ids, {'local', 'remote'});
  });

  test('顺序：文档 updated_at 大者一侧为基准，另一侧独有追加尾部', () {
    final local = CategoryDocument(
        updatedAt: 300, categories: [cat('a', 'a', 1), cat('b', 'b', 1)]);
    final remote = CategoryDocument(
        updatedAt: 100,
        categories: [cat('c', 'c', 1), cat('a', 'a', 1)]);
    final merged = mergeCategoryDocuments(local: local, remote: remote);
    expect(merged.categories.map((c) => c.id).toList(), ['a', 'b', 'c']);
  });

  test('子事件随胜出分类整体替换', () {
    final local = CategoryDocument(
        updatedAt: 100,
        categories: [cat('a', '工作', 200, subs: ['会议', '文档'])]);
    final remote = CategoryDocument(
        updatedAt: 200,
        categories: [cat('a', '工作', 300, subs: ['会议', '出差'])]);
    final merged = mergeCategoryDocuments(local: local, remote: remote);
    expect(merged.categories.single.subCategories, ['会议', '出差']);
  });

  test('parse/encode 往返一致', () {
    final doc = CategoryDocument(
        updatedAt: 123,
        categories: [cat('a', '工作', 456)],
        deletedCategories: {'b': 789});
    final encoded = encodeCategoryDocument(doc, nowMs: 123);
    final parsed = parseCategoryDocument(encoded);
    expect(parsed.updatedAt, 123);
    expect(parsed.categories.single.name, '工作');
    expect(parsed.categories.single.updatedAt, 456);
    expect(parsed.deletedCategories['b'], 789);
  });

  test('解析失败/空返回空文档', () {
    expect(parseCategoryDocument(null).updatedAt, 0);
    expect(parseCategoryDocument('bad json').categories, isEmpty);
    expect(parseCategoryDocument('').deletedCategories, isEmpty);
  });

  test('两身份互不影响：本地文档输入不被修改', () {
    final local = CategoryDocument(
        updatedAt: 100, categories: [cat('a', '本地', 200)]);
    final remote = CategoryDocument(
        updatedAt: 200, categories: [cat('a', '远端', 300)]);
    mergeCategoryDocuments(local: local, remote: remote);
    // 输入文档保持不变（merge 不修改入参）
    expect(local.categories.single.name, '本地');
    expect(remote.categories.single.name, '远端');
    expect(local.deletedCategories, isEmpty);
  });
}
