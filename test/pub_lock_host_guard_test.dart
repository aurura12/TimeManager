import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 两台开发机共用 pubspec.lock，里面记录的依赖下载源必须一致。
///
/// pub 每次跑 `pub get` 都会把每个 hosted 包的 `description.url` 改写成当前
/// 进程的 `PUB_HOSTED_URL`，即使版本完全没变。没带镜像变量跑一次就会把 165 行
/// 改回 pub.dev，另一台机器再改回来，锁文件来回翻转。
///
/// 环境配置见 docs/mac-setup-checklist.md 第 2 节。
const String _canonicalHost = 'https://pub.flutter-io.cn';

void main() {
  test('pubspec.lock 里的依赖下载源统一为 $_canonicalHost', () {
    final lines = File('pubspec.lock').readAsStringSync().split(RegExp(r'\r?\n'));

    // 按顶层包块解析，只校验 source 为 hosted 的条目：git / path / sdk 依赖
    // 没有 url，或者 url 是仓库地址，不应该命中。
    final hostedHosts = <String, String>{};
    String? package;
    var hosted = false;
    String? url;

    void flush() {
      final name = package;
      if (name != null && hosted) {
        hostedHosts[name] = url ?? '<missing>';
      }
    }

    for (final line in lines) {
      final header = RegExp(r'^  ([a-z0-9_]+):$').firstMatch(line);
      if (header != null) {
        flush();
        package = header.group(1);
        hosted = false;
        url = null;
        continue;
      }
      if (line == '    source: hosted') {
        hosted = true;
        continue;
      }
      final urlMatch = RegExp(r'^      url: "?([^"]+?)"?$').firstMatch(line);
      if (urlMatch != null) url = urlMatch.group(1);
    }
    flush();

    // 防结构漂移：锁文件格式变化导致一条都没解析到时不能静默通过。
    expect(
      hostedHosts.length,
      greaterThan(100),
      reason: '没有解析到 hosted 依赖，pubspec.lock 的结构可能变了，请更新本测试',
    );

    final offenders = hostedHosts.entries
        .where((entry) => entry.value != _canonicalHost)
        .toList();
    expect(
      offenders,
      isEmpty,
      reason: '以下依赖的下载源不是 $_canonicalHost：\n'
          '${offenders.map((e) => '  ${e.key}: ${e.value}').join('\n')}\n'
          '在带镜像变量的终端里重新解析，不要把 pub.dev 的改写提交上去：\n'
          '  PUB_HOSTED_URL=$_canonicalHost '
          'FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn flutter pub get\n'
          '  锁文件仍有改动时：git checkout -- pubspec.lock',
    );
  });
}
