import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'check_in_gitee_service.dart';
import 'check_in_photo_resource.dart';

class _PhotoCacheLocation {
  const _PhotoCacheLocation({required this.root, required this.file});

  final Directory root;
  final File file;
}

/// 打卡照片本地缓存（从 GitHub 拉取后存本地，避免重复请求）
class CheckInPhotoCache {
  static Future<void> _writeQueue = Future<void>.value();
  static int _temporaryFileSequence = 0;

  /// Test-only hook used to exercise failures before the cache file is
  /// replaced, while keeping the previous file in place.
  @visibleForTesting
  static Future<void> Function(File file, Uint8List bytes)?
      writeBytesForTesting;

  static Future<T> _withWriteQueue<T>(Future<T> Function() operation) {
    final result = _writeQueue.then<T>((_) => operation());
    _writeQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  static Future<_PhotoCacheLocation?> _cacheLocation(String photoPath) async {
    final normalizedPath = CheckInPhotoResource.normalizePath(photoPath);
    if (normalizedPath == null) return null;

    final dir = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(dir.path, 'check_in_photos'));
    final safeName = normalizedPath.replaceAll('/', '__');
    final file = File(p.join(root.path, safeName));

    final rootPath = p.normalize(root.path);
    final filePath = p.normalize(file.path);
    if (!p.isWithin(rootPath, filePath)) return null;

    // A symlink at the cache root or target would turn a safe-looking path
    // into an arbitrary filesystem write/read.
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
    return _PhotoCacheLocation(root: root, file: file);
  }

  static Future<File?> getCachedFile(String photoPath) async {
    try {
      final location = await _cacheLocation(photoPath);
      if (location == null || !await location.file.exists()) return null;

      final stat = await location.file.stat();
      if (stat.size > CheckInPhotoResource.maxPhotoBytes) {
        await location.file.delete();
        return null;
      }
      final bytes = await location.file.readAsBytes();
      if (await CheckInPhotoResource.validateBytes(bytes) != null) {
        await location.file.delete();
        return null;
      }
      return location.file;
    } catch (_) {
      return null;
    }
  }

  static Future<List<({File file, int size, DateTime modified})>> _cacheFiles(
      Directory root) async {
    final files = <({File file, int size, DateTime modified})>[];
    if (!await root.exists()) return files;
    try {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final fileName = p.basename(entity.path);
        if (fileName.startsWith('.photo-cache-') && fileName.endsWith('.tmp')) {
          // A process may have been interrupted after the temp file was
          // flushed but before rename. It is not part of the usable cache.
          continue;
        }
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file) continue;
        final stat = await entity.stat();
        files.add((file: entity, size: stat.size, modified: stat.modified));
      }
    } catch (_) {
      // An unreadable entry is not a candidate for eviction; saveBytes will
      // fail closed if it cannot establish enough free space.
    }
    return files;
  }

  static Future<File?> saveBytes(
    String photoPath,
    Uint8List bytes, {
    int maxCacheBytes = CheckInPhotoResource.maxCacheBytes,
  }) {
    return _withWriteQueue(() async {
      try {
        final location = await _cacheLocation(photoPath);
        if (location == null || maxCacheBytes <= 0) return null;

        if (await CheckInPhotoResource.validateBytes(bytes) != null) {
          return null;
        }

        await location.root.create(recursive: true);
        if (await FileSystemEntity.type(
              location.root.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
          return null;
        }

        final cacheFiles = await _cacheFiles(location.root);
        var currentSize = cacheFiles.fold<int>(
          0,
          (total, entry) => total + entry.size,
        );
        var existingSize = 0;
        if (await location.file.exists()) {
          final type = await FileSystemEntity.type(
            location.file.path,
            followLinks: false,
          );
          if (type != FileSystemEntityType.file) return null;
          existingSize = await location.file.length();
        }
        if (currentSize - existingSize + bytes.length > maxCacheBytes) {
          // 淘汰最久未修改的其它照片，避免缓存达到上限后新照片静默
          // 变成“未拍照”。当前要替换的文件不能被淘汰。
          final destinationPath = p.normalize(location.file.path);
          final candidates = cacheFiles
              .where((entry) => p.normalize(entry.file.path) != destinationPath)
              .toList()
            ..sort((a, b) => a.modified.compareTo(b.modified));
          for (final candidate in candidates) {
            if (currentSize - existingSize + bytes.length <= maxCacheBytes) {
              break;
            }
            try {
              await candidate.file.delete();
              currentSize -= candidate.size;
            } catch (_) {
              // 继续尝试下一个候选；如果仍然空间不足，下面安全失败。
            }
          }
          if (currentSize - existingSize + bytes.length > maxCacheBytes) {
            return null;
          }
        }

        // The path has already been normalized and proven to stay inside the
        // app-owned cache directory. Invalid content never reaches this write.
        // Keep the temporary file in the same directory so rename is atomic
        // on the same filesystem. The old file is untouched until rename
        // succeeds.
        final temporaryName =
            '.photo-cache-${DateTime.now().microsecondsSinceEpoch}-'
            '${_temporaryFileSequence++}.tmp';
        final temporaryFile = File(p.join(location.root.path, temporaryName));
        try {
          await _writeBytes(temporaryFile, bytes);
          await temporaryFile.rename(location.file.path);
        } finally {
          if (await temporaryFile.exists()) {
            try {
              await temporaryFile.delete();
            } catch (_) {
              // A failed cleanup leaves only an unreferenced temporary file.
            }
          }
        }
        return location.file;
      } catch (_) {
        return null;
      }
    });
  }

  static Future<void> _writeBytes(File file, Uint8List bytes) async {
    final writer = writeBytesForTesting;
    if (writer != null) {
      await writer(file, bytes);
      return;
    }
    await file.writeAsBytes(bytes, flush: true);
  }

  static Future<File?> loadOrFetch({
    required String token,
    required String photoPath,
  }) async {
    if (CheckInPhotoResource.normalizePath(photoPath) == null) return null;

    final cached = await getCachedFile(photoPath);
    if (cached != null) return cached;

    final result = await CheckInGiteeService.pullBinary(
      token: token,
      path: photoPath,
    );
    if (!result.success || result.bytes == null) return null;
    return saveBytes(photoPath, result.bytes!);
  }
}
