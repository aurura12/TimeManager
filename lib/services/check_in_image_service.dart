import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 打卡照片压缩（上传前缩小体积）
class CheckInImageService {
  static const int maxWidth = 1280;
  static const int quality = 78;

  static Future<Uint8List?> compressFile(File file) async {
    if (kIsWeb) return file.readAsBytes();

    final tempDir = await getTemporaryDirectory();
    final targetPath = p.join(
      tempDir.path,
      'check_in_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );

    final result = await FlutterImageCompress.compressAndGetFile(
      file.absolute.path,
      targetPath,
      quality: quality,
      minWidth: maxWidth,
      minHeight: maxWidth,
      format: CompressFormat.jpeg,
    );

    if (result == null) return null;
    final bytes = await File(result.path).readAsBytes();
    try {
      await File(result.path).delete();
    } catch (_) {}
    return bytes;
  }
}
