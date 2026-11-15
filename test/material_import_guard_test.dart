import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：界面组件库已统一到 material_ui。
///
/// Flutter 3.50 起 package:flutter/material.dart 整体弃用，新旧两套库的类
/// 同名但不是同一类型：同一文件混用会大面积 ambiguous，本地化代理也会因为
/// 类型不匹配在运行期找不到 MaterialLocalizations。analyze 会把旧导入报成
/// deprecated_member_use，直接让 scripts/ 下的 analyze 门禁失败，所以从源码
/// 层面禁止回流。
void main() {
  test('lib/ 与 test/ 不再 import 已弃用的 flutter material 组件库', () {
    final rules = <String, String>{
      r'package:flutter/material\.dart':
          '改用 package:material_ui/material_ui.dart',
      r'package:flutter/cupertino\.dart':
          '改用 package:cupertino_ui/cupertino_ui.dart',
      r'package:flutter_localizations/flutter_localizations\.dart':
          '本地化改用 material_ui 的 GlobalMaterialLocalizations.delegates',
    };

    final offenders = <String>[];
    for (final root in <String>['lib', 'test']) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (!line.contains('import ')) continue;
          rules.forEach((pattern, hint) {
            if (RegExp(pattern).hasMatch(line)) {
              offenders.add('$path:${i + 1} 命中已弃用的 $pattern → $hint');
            }
          });
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '界面组件库已统一到 material_ui，不要再引回旧库：\n'
          '${offenders.join('\n')}',
    );
  });
}
