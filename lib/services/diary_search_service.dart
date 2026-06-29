import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../models/diary_search_result.dart';
import 'diary_github_service.dart';

class DiarySearchService {
  static final Map<String, String> _cache = {};
  static final Map<String, String> _cacheSha = {};
  static bool _loaded = false;
  static bool _loading = false;
  static DateTime? _lastLoadTime;
  static const Duration _cacheExpiry = Duration(days: 365);
  static String? _cacheDir;

  static bool get isLoaded => _loaded;
  static bool get isLoading => _loading;

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

    if (_loaded && _lastLoadTime != null) {
      final elapsed = DateTime.now().difference(_lastLoadTime!);
      if (elapsed < _cacheExpiry) return;
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
    try {
      final listResult =
          await DiaryGitHubService.listDiaryPathsWithSha(token: token);
      if (!listResult.success) return;

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

      // 分批并行下载，每批 10 个
      await _batchDownload(token, toDownload);

      // 移除远程已删除的条目
      final remoteKeys = <String>{};
      for (final entry in filtered) {
        final key = _keyFromPath(entry.key);
        if (key != null) remoteKeys.add(key);
      }
      _cache.removeWhere((key, _) => !remoteKeys.contains(key));
      _cacheSha.removeWhere((key, _) => !remoteKeys.contains(key));

      _loaded = true;
      _lastLoadTime = DateTime.now();
      await _saveToDisk();
    } finally {
      _loading = false;
    }
  }

  /// 分批并行下载，每批 10 个
  static Future<void> _batchDownload(
    String token,
    List<MapEntry<String, String>> entries,
  ) async {
    const batchSize = 10;
    for (int i = 0; i < entries.length; i += batchSize) {
      final end = (i + batchSize).clamp(0, entries.length);
      final batch = entries.sublist(i, end);

      await Future.wait(batch.map((entry) async {
        final path = entry.key;
        final sha = entry.value;
        final pullResult = await DiaryGitHubService.pullDiary(
          token: token,
          path: path,
        );
        if (pullResult.success && pullResult.content != null) {
          final key = _keyFromPath(path);
          if (key != null) {
            _cache[key] = pullResult.content!;
            _cacheSha[key] = sha;
          }
        }
      }));
    }
  }

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

      for (int i = 1; i < lines.length; i++) {
        final line = lines[i];
        final parts = line.split(':');
        if (parts.length < 3) continue;

        final key = parts[0];
        final sha = parts[1];
        final fileName = parts.sublist(2).join(':');

        final contentFile = File('$dir/$fileName');
        if (await contentFile.exists()) {
          _cache[key] = await contentFile.readAsString();
          _cacheSha[key] = sha;
        }
      }

      _loaded = true;
    } catch (e) {
      // 加载失败，忽略
    }
  }

  static Future<void> _saveToDisk() async {
    try {
      final dir = await _getCacheDir();

      // 清理旧缓存
      final existingFiles = await Directory(dir).list().toList();
      for (final file in existingFiles) {
        if (file is File) await file.delete();
      }

      // 保存索引
      final indexLines = <String>[];
      indexLines.add(_lastLoadTime?.toIso8601String() ?? '');

      int fileIndex = 0;
      for (final entry in _cache.entries) {
        final key = entry.key;
        final sha = _cacheSha[key] ?? '';
        final fileName = 'cache_$fileIndex.txt';
        final contentFile = File('$dir/$fileName');
        await contentFile.writeAsString(entry.value);
        indexLines.add('$key:$sha:$fileName');
        fileIndex++;
      }

      final indexFile = File('$dir/index.txt');
      await indexFile.writeAsString(indexLines.join('\n'));
    } catch (e) {
      // 保存失败，忽略
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
      final content = entry.value;

      final parts = key.split('_');
      if (parts.length != 2) continue;

      final kind = parts[0];
      final dateStr = parts[1];
      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;

      final lowerContent = content.toLowerCase();
      final matchIndex = lowerContent.indexOf(lowerQuery);
      if (matchIndex == -1) continue;

      final snippet = _extractSnippet(content, matchIndex, query.length);

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
    _cacheSha.remove(key); // 清除 sha，下次刷新时会重新同步
  }

  static void removeFromCache(String kind, DateTime date) {
    final key = '${kind}_${DateFormat('yyyy-MM-dd').format(date)}';
    _cache.remove(key);
    _cacheSha.remove(key);
  }

  static void clearCache() {
    _cache.clear();
    _cacheSha.clear();
    _loaded = false;
    _lastLoadTime = null;
  }
}
