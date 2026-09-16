import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/services/target_document_merge.dart';

Target target(String id, String name, int updatedAt) {
  return Target(
    id: id,
    name: name,
    type: TargetType.duration,
    color: const Color(0xFF9CB86A),
    period: '每天',
    durationHours: 1,
    updatedAt: updatedAt,
  );
}

void main() {
  test('同 ID 目标取 updatedAt 较新的版本', () {
    final merged = mergeTargetDocuments(
      local: TargetDocument(
        updatedAt: 100,
        targets: [target('a', '本地', 200)],
      ),
      remote: TargetDocument(
        updatedAt: 200,
        targets: [target('a', '远端', 300)],
      ),
    );

    expect(merged.targets.single.name, '远端');
  });

  test('删除墓碑时间更新时不会让旧目标复活', () {
    final merged = mergeTargetDocuments(
      local: TargetDocument(
        updatedAt: 100,
        targets: [target('a', '本地', 200)],
      ),
      remote: TargetDocument(
        updatedAt: 200,
        deletedTargets: {'a': 500},
      ),
    );

    expect(merged.targets, isEmpty);
    expect(merged.deletedTargets['a'], 500);
  });

  test('目标更新时间更新时可以复活更旧的删除墓碑', () {
    final merged = mergeTargetDocuments(
      local: TargetDocument(
        updatedAt: 100,
        targets: [target('a', '重新启用', 600)],
      ),
      remote: TargetDocument(
        updatedAt: 200,
        deletedTargets: {'a': 500},
      ),
    );

    expect(merged.targets.single.name, '重新启用');
  });

  test('两侧目标和删除墓碑都取并集', () {
    final merged = mergeTargetDocuments(
      local: TargetDocument(
        updatedAt: 100,
        targets: [target('local', '本地', 100)],
        deletedTargets: {'old': 500},
      ),
      remote: TargetDocument(
        updatedAt: 200,
        targets: [target('remote', '远端', 100)],
        deletedTargets: {'old': 400, 'remote-deleted': 600},
      ),
    );

    expect(merged.targets.map((item) => item.id), ['remote', 'local']);
    expect(merged.deletedTargets, {'old': 500, 'remote-deleted': 600});
  });

  test('文档更新时间较新的一侧决定目标顺序', () {
    final merged = mergeTargetDocuments(
      local: TargetDocument(
        updatedAt: 300,
        targets: [target('a', 'a', 1), target('b', 'b', 1)],
      ),
      remote: TargetDocument(
        updatedAt: 100,
        targets: [target('c', 'c', 1), target('a', 'a', 1)],
      ),
    );

    expect(merged.targets.map((item) => item.id), ['a', 'b', 'c']);
  });

  test('目标文档 JSON 可以往返解析', () {
    final encoded = encodeTargetDocument(
      TargetDocument(
        updatedAt: 123,
        targets: [target('a', '阅读', 456)],
        deletedTargets: {'b': 789},
      ),
      nowMs: 123,
    );

    final parsed = parseTargetDocument(encoded);

    expect(parsed.updatedAt, 123);
    expect(parsed.targets.single.name, '阅读');
    expect(parsed.targets.single.updatedAt, 456);
    expect(parsed.deletedTargets['b'], 789);
  });

  test('目标业务内容相同但 updated_at 不同，不需要再次上传', () {
    final left = TargetDocument(
      updatedAt: 100,
      targets: [target('a', '阅读', 456)],
      deletedTargets: {'b': 789},
    );
    final right = TargetDocument(
      updatedAt: 999,
      targets: [target('a', '阅读', 456)],
      deletedTargets: {'b': 789},
    );

    expect(targetDocumentsEquivalent(left, right), isTrue);
  });

  test('目标列表顺序属于业务内容，纯重排不能判定为等价', () {
    final left = TargetDocument(
      targets: [target('a', '阅读', 456), target('b', '运动', 456)],
    );
    final right = TargetDocument(
      targets: [target('b', '运动', 456), target('a', '阅读', 456)],
    );

    expect(targetDocumentsEquivalent(left, right), isFalse);
  });

  test('目标业务内容不同，必须继续上传', () {
    final left = TargetDocument(
      updatedAt: 100,
      targets: [target('a', '本地', 456)],
    );
    final right = TargetDocument(
      updatedAt: 999,
      targets: [target('a', '远端', 456)],
    );

    expect(targetDocumentsEquivalent(left, right), isFalse);
  });

  test('空内容或非法 JSON 返回空目标文档', () {
    expect(parseTargetDocument(null).updatedAt, 0);
    expect(parseTargetDocument('').targets, isEmpty);
    expect(parseTargetDocument('not-json').deletedTargets, isEmpty);
    expect(parseTargetDocument('not-json').isValid, isFalse);
  });

  test('合并不会修改输入文档', () {
    final local = TargetDocument(
      updatedAt: 100,
      targets: [target('a', '本地', 200)],
    );
    final remote = TargetDocument(
      updatedAt: 200,
      targets: [target('a', '远端', 300)],
    );

    mergeTargetDocuments(local: local, remote: remote);

    expect(local.targets.single.name, '本地');
    expect(remote.targets.single.name, '远端');
  });
}
