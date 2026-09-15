import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/check_in_document.dart';
import '../models/known_google_users.dart';

/// Shared validation rules for check-in photo paths and payloads.
///
/// Photo paths are data received from the remote check-in document, so they
/// must not be treated as arbitrary filesystem or repository paths.
class CheckInPhotoResource {
  CheckInPhotoResource._();

  static const int maxPhotoBytes = 10 * 1024 * 1024;
  static const int maxRemoteResponseBytes = 14 * 1024 * 1024;
  static const int maxCacheBytes = 100 * 1024 * 1024;
  static const int maxDecodedDimension = 8192;
  static const int maxEncodedPixels = 50 * 1000 * 1000;
  static const int maxDecodedPixels = 20 * 1000 * 1000;
  static const int maxPathLength = 256;

  static final RegExp _drivePath = RegExp(r'^[A-Za-z]:');
  static final RegExp _controlCharacter = RegExp(r'[\x00-\x1F\x7F]');
  static final RegExp _photoFileName = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:jpe?g|png|webp)$',
    caseSensitive: false,
  );

  /// Returns a canonical repository-relative path, or null when [rawPath] is
  /// not one of the app's supported photo paths.
  ///
  /// Windows separators are accepted for compatibility, but are normalized
  /// to `/` before the path is sent to the repository or used as a cache key.
  static String? normalizePath(String rawPath) {
    if (rawPath.isEmpty || rawPath.length > maxPathLength) return null;
    if (_controlCharacter.hasMatch(rawPath)) return null;

    final normalized = rawPath.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        normalized.startsWith('//') ||
        _drivePath.hasMatch(normalized) ||
        normalized.contains('://')) {
      return null;
    }

    final parts = normalized.split('/');
    if (parts.length != 3 || parts.any((part) => part.isEmpty)) return null;
    if (parts.any((part) => part == '.' || part == '..')) return null;
    if (parts.first != CheckInDocument.imagesDir) return null;

    final folder = parts[1];
    final isKnownFolder = folder == 'other' ||
        KnownGoogleUsers.nicknamesByEmail.values.contains(folder);
    if (!isKnownFolder || !_photoFileName.hasMatch(parts[2])) return null;

    return parts.join('/');
  }

  /// Validates the encoded image and its decoded dimensions.
  ///
  /// A codec is created and asked to decode one frame so truncated or
  /// malformed images do not enter the cache or get uploaded. Large images
  /// are rejected before decoding; valid images within the pixel budget are
  /// decoded at a bounded size to keep memory use predictable.
  static Future<String?> validateBytes(
    Uint8List bytes, {
    int maxBytes = maxPhotoBytes,
  }) async {
    if (bytes.isEmpty) return '照片内容为空';
    if (bytes.length > maxBytes) return '照片超过大小限制';

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 ||
          height <= 0 ||
          width > maxDecodedDimension ||
          height > maxDecodedDimension ||
          width * height > maxEncodedPixels) {
        return '照片分辨率超过限制';
      }

      var targetWidth = width;
      var targetHeight = height;
      final pixelCount = width * height;
      if (pixelCount > maxDecodedPixels) {
        final scale = math.sqrt(maxDecodedPixels / pixelCount);
        targetWidth = math.max(1, (width * scale).floor());
        targetHeight = math.max(1, (height * scale).floor());
      }

      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      if (codec.frameCount != 1) return '不支持多帧照片';
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      return null;
    } catch (_) {
      return '照片内容无法解码';
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
