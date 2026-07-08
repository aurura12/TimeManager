import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../models/diary_search_result.dart';
import 'diary_gitee_service.dart';

class DiarySearchService {
  static final Map<String, String> _cache = {};
  static final Map<String, String> _cacheSha = {};
  /// 预计算的小写内容缓存，搜索时避免重复 toLowerCase
  static final Map<String, String> _lowerCache = {};
  static bool _loaded = false;
  static bool _loading = false;
  static DateTime? _lastLoadTime;
  static const Duration _cacheExpiry = Duration(days: 365);
  static String? _cacheDir;

  /// 索引进度（0.0 ~ 1.0），通过 addListener 监听变化
  static final ValueNotifier<double> progress = ValueNotifier(0);
  static int _totalToSync = 0;
  static int _syncedCount = 0;

  static bool get isLoaded => _loaded;
  static bool get isLoading => _loading;
  static bool get hasData => _cache.isNotEmpty;

  static Future<String> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = '${appDir.path}/diary_cache';
    await Directory(_cacheDir!).create(recursive: true);
    return _cacheDir!;
  }

  static Future<void> loadInBackground(String token) async {
    if (token.isEmpty || _loading) return;

    await _loadFromDisk();

    // 磁盘缓存有效且未过期，直接使用
    if (_loaded && _cache.isNotEmpty && _lastLoadTime != null) {
      final elapsed = DateTime.now().difference(_lastLoadTime!);
      if (elapsed < _cacheExpiry) {
        progress.value = 1.0;
        return;
      }
    }

    await _syncFromRemote(token);
  }

  static Future<void> refreshCache(String token) async {
    if (token.isEmpty || _loading) return;
    await _syncFromRemote(token);
  }

  /// 从远程同步缓存（增量 + 并行下载）
  static Future<void> _syncFromRemote(String token) async {
    _loading = true;
    progress.value = 0;
    try {
      final listResult =
          await DiaryGiteeService.listDiaryPathsWithSha(token: token);
      if (!listResult.success) {
        debugPrint('日记索引: 获取远程文件列表失败: ${listResult.error}');
        return;
      }

      final pathShaMap = listResult.pathShaMap;
      final filtered = pathShaMap.entries.where((e) {
        final fileName = e.key.split('/').last;
        return fileName.endsWith('.md') &&
            (fileName.startsWith('G') || fileName.startsWith('J'));
      }).toList();

      // 增量：只下载 sha 变化的文件
      final toDownload = <MapEntry<String, String>>[];
      for (final entry in filtered) {
        final key = _keyFromPath(entry.key);
        if (key == null) continue;
        if (_cacheSha[key] != entry.value) {
          toDownload.add(entry);
        }
      }

      // 如果没有需要下载的，进度直接完成
      _totalToSync = toDownload.length;
      _syncedCount = 0;
      if (toDownload.isEmpty) {
        progress.value = 1.0;
      } else {
        await _batchDownload(token, toDownload);
      }

      // 移除远程已删除的条目
      final remoteKeys = <String>{};
      for (final entry in filtered) {
        final key = _keyFromPath(entry.key);
        if (key != null) remoteKeys.add(key);
      }
      _cache.removeWhere((key, _) => !remoteKeys.contains(key));
      _cacheSha.removeWhere((key, _) => !remoteKeys.contains(key));
      _lowerCache.clear();

      _loaded = true;
      _lastLoadTime = DateTime.now();
      progress.value = 1.0;
      await _saveToDisk();
    } finally {
      _loading = false;
    }
  }

  /// 并发下载，动态并发数（最多 30 个同时进行）
  static Future<void> _batchDownload(
    String token,
    List<MapEntry<String, String>> entries,
  ) async {
    const maxConcurrent = 30;
    int inFlight = 0;
    int nextIndex = 0;
    final completer = Completer<void>();

    void startNext() {
      while (inFlight < maxConcurrent && nextIndex < entries.length) {
        final entry = entries[nextIndex++];
        inFlight++;
        _downloadOne(token, entry).whenComplete(() {
          inFlight--;
          _syncedCount++;
          progress.value = _totalToSync > 0 ? _syncedCount / _totalToSync : 1.0;
          if (_syncedCount >= _totalToSync) {
            completer.complete();
          } else {
            startNext();
          }
        });
      }
    }

    startNext();
    await completer.future;
  }

  static Future<void> _downloadOne(
    String token,
    MapEntry<String, String> entry,
  ) async {
    final pullResult = await DiaryGiteeService.pullDiary(
      token: token,
      path: entry.key,
    );
    if (pullResult.success && pullResult.content != null) {
      final key = _keyFromPath(entry.key);
      if (key != null) {
        _cache[key] = pullResult.content!;
        _cacheSha[key] = entry.value;
      }
    }
  }

  /// 并行从磁盘加载所有缓存文件
  static Future<void> _loadFromDisk() async {
    try {
      final dir = await _getCacheDir();
      final indexFile = File('$dir/index.txt');
      if (!await indexFile.exists()) return;

      final lines = await indexFile.readAsLines();
      if (lines.length < 2) return;

      _lastLoadTime = DateTime.tryParse(lines[0]);
      _cache.clear();
      _cacheSha.clear();
      _lowerCache.clear();

      // 解析索引行，收集需要读取的文件
      final entries = <(String key, String sha, String fileName)>[];
      for (int i = 1; i < lines.length; i++) {
        final line = lines[i];
        final parts = line.split(':');
        if (parts.length < 3) continue;
        final key = parts[0];
        final sha = parts[1];
        final fileName = parts.sublist(2).join(':');
        entries.add((key, sha, fileName));
      }

      // 并行读取所有缓存文件
      await Future.wait(entries.map((entry) async {
        final contentFile = File('$dir/${entry.$3}');
        if (await contentFile.exists()) {
          final content = await contentFile.readAsString();
          _cache[entry.$1] = content;
          _cacheSha[entry.$1] = entry.$2;
        }
      }));

      _loaded = true;
    } catch (e) {
      debugPrint('日记索引: 从磁盘加载失败: $e');
    }
  }

  /// 并行写入所有缓存文件
  static Future<void> _saveToDisk() async {
    try {
      final dir = await _getCacheDir();

      // 清理旧缓存
      final existingFiles = await Directory(dir).list().toList();
      await Future.wait(existingFiles
          .whereType<File>()
          .map((f) => f.delete().catchError((_) => f)));

      // 并行写入所有缓存文件
      final indexLines = <String>[];
      indexLines.add(_lastLoadTime?.toIso8601String() ?? '');

      final entries = _cache.entries.toList();
      final keys = entries.map((e) => e.key).toList();

      await Future.wait(List.generate(entries.length, (i) {
        final fileName = 'cache_$i.txt';
        final contentFile = File('$dir/$fileName');
        return contentFile.writeAsString(entries[i].value);
      }));

      // 构建索引文件内容
      for (int i = 0; i < entries.length; i++) {
        final key = keys[i];
        final sha = _cacheSha[key] ?? '';
        indexLines.add('$key:$sha:cache_$i.txt');
      }

      final indexFile = File('$dir/index.txt');
      await indexFile.writeAsString(indexLines.join('\n'));
    } catch (e) {
      debugPrint('日记索引: 保存到磁盘失败: $e');
    }
  }

  static String? _keyFromPath(String path) {
    final fileName = path.split('/').last;
    if (!fileName.endsWith('.md')) return null;

    final kind = fileName.startsWith('G') ? 'g' : 'j';
    final date = _parseDateFromFileName(fileName);
    if (date == null) return null;

    return '${kind}_${DateFormat('yyyy-MM-dd').format(date)}';
  }

  static DateTime? _parseDateFromFileName(String fileName) {
    final match =
        RegExp(r'(\d{4})年(\d{1,2})月(\d{1,2})日').firstMatch(fileName);
    if (match == null) return null;
    final year = int.tryParse(match.group(1) ?? '');
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  /// 通过 kind 和 date 查询缓存内容，未命中返回 null
  static String? getCachedContent(String kind, DateTime date) {
    if (!_loaded) return null;
    final key = '${kind}_${DateFormat('yyyy-MM-dd').format(date)}';
    return _cache[key];
  }

  /// 通过远程路径查询缓存内容，未命中返回 null
  static String? getCachedContentByPath(String path) {
    if (!_loaded) return null;
    final key = _keyFromPath(path);
    if (key == null) return null;
    return _cache[key];
  }

  static List<DiarySearchResult> search(String query) {
    if (!_loaded || query.trim().isEmpty) return [];

    final results = <DiarySearchResult>[];
    final lowerQuery = query.toLowerCase();

    for (final entry in _cache.entries) {
      final key = entry.key;

      final parts = key.split('_');
      if (parts.length != 2) continue;

      final kind = parts[0];
      final dateStr = parts[1];
      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;

      // 使用预计算的小写缓存
      final lowerContent = _lowerCache.putIfAbsent(
        key,
        () => entry.value.toLowerCase(),
      );
      final matchIndex = lowerContent.indexOf(lowerQuery);
      if (matchIndex == -1) continue;

      final snippet = _extractSnippet(entry.value, matchIndex, query.length);

      results.add(DiarySearchResult(
        kind: kind,
        date: date,
        snippet: snippet,
        matchIndex: matchIndex,
      ));
    }

    results.sort((a, b) => b.date.compareTo(a.date));
    return results;
  }

  static String _extractSnippet(
      String content, int matchIndex, int matchLength) {
    const snippetRadius = 30;
    final start = (matchIndex - snippetRadius).clamp(0, content.length);
    final end = (matchIndex + matchLength + snippetRadius).clamp(0, content.length);

    var snippet = content.substring(start, end).replaceAll('\n', ' ');
    if (start > 0) snippet = '...$snippet';
    if (end < content.length) snippet = '$snippet...';

    return snippet;
  }

  static void updateCache(String kind, DateTime date, String content) {
    final key = '${kind}_${DateFormat('yyyy-MM-dd').format(date)}';
    _cache[key] = content;
    _cacheSha.remove(key);
    _lowerCache.remove(key);
  }

  static void removeFromCache(String kind, DateTime date) {
    final key = '${kind}_${DateFormat('yyyy-MM-dd').format(date)}';
    _cache.remove(key);
    _cacheSha.remove(key);
    _lowerCache.remove(key);
  }

  static void clearCache() {
    _cache.clear();
    _cacheSha.clear();
    _lowerCache.clear();
    _loaded = false;
    _lastLoadTime = null;
  }
}
