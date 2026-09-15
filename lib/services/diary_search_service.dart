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
  // 磁盘缓存有效期 1 天：每天首次启动自动增量同步远程（只下载 sha 变化的文件），
  // 避免旧的磁盘缓存长期不刷新导致漏掉新增日记（如某位用户的日记）。
  static const Duration _cacheExpiry = Duration(days: 1);
  static String? _cacheDir;
  static int _saveSequence = 0;
  static Future<void> _saveQueue = Future<void>.value();

  /// Test-only hook used to exercise disk-write failures without changing the
  /// production cache directory permissions.
  @visibleForTesting
  static Future<void> Function(File file, String content)? writeTextForTesting;

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

    // 必须在第一次 await 之前抢占加载锁，避免多个页面同时启动索引。
    _loading = true;
    try {
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
    } finally {
      _loading = false;
    }
  }

  static Future<void> refreshCache(String token) async {
    if (token.isEmpty || _loading) return;
    _loading = true;
    try {
      await _syncFromRemote(token);
    } finally {
      _loading = false;
    }
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
            if (!completer.isCompleted) completer.complete();
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

  /// 以新一代文件集合写入所有缓存文件
  static Future<void> _saveToDisk() async {
    final result = _saveQueue.then<void>((_) => _saveToDiskOnce());
    _saveQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    await result;
  }

  static Future<void> _saveToDiskOnce() async {
    Directory? stagingDirectory;
    final newContentFileNames = <String>[];
    var committed = false;
    try {
      final dir = await _getCacheDir();
      final generation =
          '${DateTime.now().microsecondsSinceEpoch}_${_saveSequence++}';
      stagingDirectory = Directory('$dir/.staging_$generation');
      await stagingDirectory.create(recursive: true);

      final indexLines = <String>[];
      indexLines.add(_lastLoadTime?.toIso8601String() ?? '');

      final entries = _cache.entries.toList();
      final keys = entries.map((e) => e.key).toList();

      // 每个内容文件先写入同一缓存目录下的 staging 目录。旧索引仍然
      // 指向旧文件，因此在新一代完全写完前，旧缓存始终可读。
      for (int i = 0; i < entries.length; i++) {
        final fileName = 'cache_${generation}_$i.txt';
        final temporaryFile = File('${stagingDirectory.path}/$fileName.tmp');
        final stagedFile = File('${stagingDirectory.path}/$fileName');
        await _writeText(temporaryFile, entries[i].value);
        await temporaryFile.rename(stagedFile.path);

        final key = keys[i];
        final sha = _cacheSha[key] ?? '';
        indexLines.add('$key:$sha:$fileName');
        newContentFileNames.add(fileName);
      }

      // 索引同样先 flush 到临时文件，再在最后一步 rename。索引替换是
      // 提交点：失败时旧 index.txt 仍然指向完整的旧文件集合。
      final temporaryIndex = File('${stagingDirectory.path}/index.txt.tmp');
      final stagedIndex = File('${stagingDirectory.path}/index.txt');
      await _writeText(temporaryIndex, indexLines.join('\n'));
      await temporaryIndex.rename(stagedIndex.path);

      // 将已完成的内容文件移动到正式目录。文件名带 generation，不会
      // 覆盖旧文件；旧索引在此期间仍保持有效。
      for (final fileName in newContentFileNames) {
        await File('${stagingDirectory.path}/$fileName')
            .rename('$dir/$fileName');
      }
      await stagedIndex.rename('$dir/index.txt');
      committed = true;

      // 新索引提交后再清理旧文件。清理失败不会影响当前一代缓存读取。
      await _removeSupersededCacheFiles(
        Directory(dir),
        keepFileNames: newContentFileNames.toSet(),
      );
    } catch (e) {
      debugPrint('日记索引: 保存到磁盘失败: $e');
    } finally {
      if (!committed) {
        // 新索引尚未提交，旧 index.txt 仍是有效入口。清理可能已经移入
        // 正式目录的新文件时，不触碰旧文件和旧索引。
        try {
          final dir = await _getCacheDir();
          for (final fileName in newContentFileNames) {
            final file = File('$dir/$fileName');
            if (await file.exists()) await file.delete();
          }
        } catch (_) {
          // 清理失败只会留下未被旧索引引用的孤儿文件，不影响旧缓存。
        }
      }
      if (stagingDirectory != null && await stagingDirectory.exists()) {
        try {
          await stagingDirectory.delete(recursive: true);
        } catch (_) {
          // 下一次保存时可继续使用新的 staging 目录。
        }
      }
    }
  }

  static Future<void> _writeText(File file, String content) async {
    final writer = writeTextForTesting;
    if (writer != null) {
      await writer(file, content);
      return;
    }
    await file.writeAsString(content, flush: true);
  }

  static Future<void> _removeSupersededCacheFiles(
    Directory dir, {
    required Set<String> keepFileNames,
  }) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final fileName = entity.uri.pathSegments.last;
        if (entity is File &&
            fileName != 'index.txt' &&
            !keepFileNames.contains(fileName)) {
          try {
            await entity.delete();
          } catch (_) {
            // Stale files are harmless; the committed index does not point to
            // them anymore.
          }
        } else if (entity is Directory && fileName.startsWith('.staging_')) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {
            // Stale staging data is safe to leave for a later cleanup.
          }
        }
      }
    } catch (_) {
      // Cache cleanup is best effort and must not turn a committed save into
      // a failed save.
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
    final match = RegExp(r'(\d{4})年(\d{1,2})月(\d{1,2})日').firstMatch(fileName);
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
    final end =
        (matchIndex + matchLength + snippetRadius).clamp(0, content.length);

    var snippet = content.substring(start, end).replaceAll('\n', ' ');
    if (start > 0) snippet = '...$snippet';
    if (end < content.length) snippet = '$snippet...';

    return snippet;
  }

  /// 更新单条缓存并立即落盘。
  ///
  /// 搜索与"那年今日"都依赖此缓存；若只改内存不落盘，重启后会被旧的
  /// 磁盘缓存覆盖，导致刚同步的日记（尤其是另一用户的日记）丢失。
  static Future<void> updateCache(
      String kind, DateTime date, String content) async {
    final key = '${kind}_${DateFormat('yyyy-MM-dd').format(date)}';
    _cache[key] = content;
    _cacheSha.remove(key);
    _lowerCache.remove(key);
    // 本地更新后缓存即视为就绪：getCachedContent/search 都依赖 _loaded，
    // 否则索引未加载时 push 的日记即使进了内存也搜不到。
    _loaded = true;
    // 刷新落盘时间：本次本地更新即视为缓存最新，重启时直接复用无需远程刷新
    _lastLoadTime = DateTime.now();
    await _saveToDisk();
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
