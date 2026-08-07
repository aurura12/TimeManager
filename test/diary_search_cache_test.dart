import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/services/diary_search_service.dart';

/// 验证 DiarySearchService 磁盘缓存的"重启后数据完整"：
/// 修复前 updateCache 只更新内存不落盘，且磁盘缓存 365 天不刷新，
/// 导致某位用户 push 的日记在重启后被旧磁盘缓存覆盖（搜索/那年今日只显示一人）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('updateCache 落盘后重启（重新从磁盘加载）数据完整', () async {
    // 将 path_provider 指向临时目录，避免污染真实文档目录
    final tempDir = await Directory.systemTemp.createTemp('diary_cache_test');
    addTearDown(() => tempDir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return tempDir.path;
        }
        return null;
      },
    );

    // 清空静态状态（内存缓存与加载标记；磁盘目录由 mock 指向的临时目录接管）
    DiarySearchService.clearCache();

    final date = DateTime(2025, 8, 7);

    // 模拟两台设备先后 push 成功：乖乖(g) 和 晶晶(j) 各写入一条。
    // 修复前 updateCache 只改内存，这里写入磁盘即为修复点。
    await DiarySearchService.updateCache('g', date, '乖乖的日记内容');
    await DiarySearchService.updateCache('j', date, '晶晶的日记内容');

    // 内存中两者都在
    expect(DiarySearchService.getCachedContent('g', date), '乖乖的日记内容');
    expect(DiarySearchService.getCachedContent('j', date), '晶晶的日记内容');

    // 模拟重启：清空内存，重新从磁盘缓存加载。
    // updateCache 已刷新 _lastLoadTime，磁盘缓存视为最新，不会触发远程刷新。
    DiarySearchService.clearCache();
    await DiarySearchService.loadInBackground('fake-token');

    // 重启后数据完整：乖乖和晶晶的日记都还在，不再只显示一人
    expect(DiarySearchService.getCachedContent('g', date), '乖乖的日记内容');
    expect(DiarySearchService.getCachedContent('j', date), '晶晶的日记内容');
  });
}
