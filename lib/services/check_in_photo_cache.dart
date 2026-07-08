import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'check_in_gitee_service.dart';

/// 打卡照片本地缓存（从 GitHub 拉取后存本地，避免重复请求）
class CheckInPhotoCache {
  static Future<File> _cacheFile(String photoPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final safeName = photoPath.replaceAll('/', '__');
    return File(p.join(dir.path, 'check_in_photos', safeName));
  }

  static Future<File?> getCachedFile(String photoPath) async {
    final file = await _cacheFile(photoPath);
    if (await file.exists()) return file;
    return null;
  }

  static Future<File> saveBytes(String photoPath, Uint8List bytes) async {
    final file = await _cacheFile(photoPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<File?> loadOrFetch({
    required String token,
    required String photoPath,
  }) async {
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
