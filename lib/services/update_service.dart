import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/diary_gitee_config.dart';
import '../config/remote_repo_config.dart';
import 'app_log_service.dart';
import '../utils/platform_features.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;
  final String? sha256;

  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
    this.sha256,
  });

  /// Whether the release metadata is sufficient for verified automatic install.
  bool get canAutoInstall => UpdateService._isValidSha256(sha256);
}

class UpdateCheckResult {
  final UpdateInfo? info;
  final String? error;

  const UpdateCheckResult({this.info, this.error});

  bool get hasUpdate => info != null;
  bool get hasError => error != null;
}

class UpdateService {
  static String get _owner => RemoteRepoConfig.giteeOwner;
  static String get _repo => 'time_manager_releases'; // 公开仓库，专用发布安装包
  static String get _token => DiaryGiteeConfig.hardcodedToken;

  static const Duration _checkTimeout = Duration(seconds: 10);
  static const Duration _downloadConnectTimeout = Duration(seconds: 20);
  static const int _maxDownloadBytes = 512 * 1024 * 1024;
  static const int _maxDiscardBytes = 64 * 1024;
  static const int _maxChecksumMetadataBytes = 8 * 1024;
  static const int _maxRedirects = 5;
  static const int _maxRetries = 1;
  static const String _checksumAssetSuffix = '.sha256';
  static const String _missingChecksumMessage =
      '发布包缺少可信的 SHA-256 校验信息，无法自动安装；请打开发布页手动下载并自行校验。';

  static final RegExp _safeVersionPattern = RegExp(
    r'^v?\d+(?:\.\d+){1,3}(?:-[0-9A-Za-z](?:[0-9A-Za-z.-]*[0-9A-Za-z])?)?(?:\+[0-9A-Za-z](?:[0-9A-Za-z.-]*[0-9A-Za-z])?)?$',
  );
  static final RegExp _safeAssetNamePattern = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
  static final RegExp _checksumManifestLinePattern = RegExp(
    r'^\s*([a-fA-F0-9]{64})\s+(\*?[A-Za-z0-9._-]+)\s*$',
  );

  // The existing UI passes only URL and version to downloadAndInstall. Keep
  // the digest from the most recent check so that API compatibility is not
  // broken while refusing downloads that were not checked first.
  static UpdateInfo? _lastCheckedUpdate;

  static Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Authorization': 'token $_token',
      };

  static Map<String, String> get _downloadHeaders => {
        'Accept': 'application/octet-stream',
        'Authorization': 'token $_token',
      };

  static bool _isRedirectStatus(int statusCode) {
    return statusCode == HttpStatus.movedPermanently ||
        statusCode == HttpStatus.found ||
        statusCode == HttpStatus.seeOther ||
        statusCode == HttpStatus.temporaryRedirect ||
        statusCode == HttpStatus.permanentRedirect;
  }

  static Uri _resolveRedirectUri(Uri baseUri, String location) {
    final redirectUri = Uri.parse(location);
    if (redirectUri.hasScheme) return redirectUri;
    return baseUri.resolveUri(redirectUri);
  }

  static bool _isSafeVersion(String version) =>
      _safeVersionPattern.hasMatch(version);

  static bool _isSafeAssetName(String name, String expectedSuffix) {
    return name.isNotEmpty &&
        name.endsWith(expectedSuffix) &&
        !name.contains('/') &&
        !name.contains('\\') &&
        !name.contains('\u0000') &&
        _safeAssetNamePattern.hasMatch(name);
  }

  static bool _hasSafeDownloadUriParts(Uri uri, String expectedHost) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != expectedHost ||
        uri.userInfo.isNotEmpty ||
        (uri.port != 0 && uri.port != 443) ||
        uri.fragment.isNotEmpty) {
      return false;
    }

    final rawPath = uri.toString().split('?').first.split('#').first;
    final lowerRawPath = rawPath.toLowerCase();
    if (rawPath.contains('\\') ||
        lowerRawPath.contains('%2e') ||
        lowerRawPath.contains('%2f') ||
        lowerRawPath.contains('%5c')) {
      return false;
    }

    final segments = uri.pathSegments;
    if (segments.any((segment) => segment == '.' || segment == '..')) {
      return false;
    }

    return true;
  }

  static bool _isAllowedDownloadUri(Uri uri) {
    if (!_hasSafeDownloadUriParts(uri, 'gitee.com')) return false;

    final segments = uri.pathSegments;

    final isApiAsset = segments.length >= 8 &&
        segments[0] == 'api' &&
        segments[1] == 'v5' &&
        segments[2] == 'repos' &&
        segments[3] == _owner &&
        segments[4] == _repo &&
        segments[5] == 'releases' &&
        segments[6] == 'assets' &&
        segments[7].isNotEmpty;
    if (isApiAsset) return true;

    final isAttachFile = segments.length >= 4 &&
        segments[0] == _owner &&
        segments[1] == _repo &&
        segments[2] == 'attach_files' &&
        segments[3].isNotEmpty;
    if (isAttachFile) return true;

    // Keep compatibility with release-download style URLs while requiring
    // the exact configured owner and repository.
    return segments.length >= 5 &&
        segments[0] == _owner &&
        segments[1] == _repo &&
        segments[2] == 'releases' &&
        segments[3] == 'download' &&
        segments[4].isNotEmpty;
  }

  /// Gitee's release download endpoint redirects the file body to its
  /// attachment CDN. This host is accepted only as a one-hop redirect from a
  /// previously validated Gitee download URL (see _sendGetFollowingRedirects).
  static bool _isAllowedGiteeCdnUri(Uri uri) {
    if (!_hasSafeDownloadUriParts(uri, 'foruda.gitee.com')) return false;

    final segments = uri.pathSegments;
    return segments.length >= 3 &&
        segments[0] == 'attach_file' &&
        RegExp(r'^\d+$').hasMatch(segments[1]) &&
        _safeAssetNamePattern.hasMatch(segments[2]);
  }

  static Uri? _parseAllowedDownloadUri(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !_isAllowedDownloadUri(uri)) return null;
    return uri;
  }

  static String? _readString(Object? value) => value is String ? value : null;

  static String? _normalizeSha256Value(Object? value) {
    if (value is! String) return null;
    var normalized = value.trim().toLowerCase();
    if (normalized.startsWith('sha256:')) {
      normalized = normalized.substring('sha256:'.length).trim();
    } else if (normalized.startsWith('sha256=')) {
      normalized = normalized.substring('sha256='.length).trim();
    }
    return _sha256Pattern.hasMatch(normalized) ? normalized : null;
  }

  static String? _extractSha256(Map<String, dynamic> asset) {
    for (final key in const ['sha256', 'sha256sum', 'checksum', 'digest']) {
      final digest = _normalizeSha256Value(asset[key]);
      if (digest != null) return digest;
    }
    return null;
  }

  /// Release metadata contract: each installer asset may be accompanied by a
  /// same-name `.sha256` asset containing one standard sha256sum line, for
  /// example: `64-hex-digest  time_manager_v1.96.0.apk`.
  static String? _parseSha256Manifest(
    String content,
    String expectedAssetName,
  ) {
    final lines = content
        .replaceFirst('\uFEFF', '')
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length != 1) return null;

    final match = _checksumManifestLinePattern.firstMatch(lines.single);
    if (match == null) return null;

    final reportedName = match.group(2)!;
    final normalizedName =
        reportedName.startsWith('*') ? reportedName.substring(1) : reportedName;
    if (normalizedName != expectedAssetName) return null;

    return _normalizeSha256Value(match.group(1));
  }

  static bool _isValidSha256(String? value) =>
      value != null && _sha256Pattern.hasMatch(value.trim().toLowerCase());

  static Uri? _assetDownloadUri(Map<String, dynamic> asset) {
    for (final key in const ['url', 'browser_download_url']) {
      final candidate = _readString(asset[key]);
      if (candidate == null) continue;
      final uri = _parseAllowedDownloadUri(candidate.trim());
      if (uri != null) return uri;
    }
    return null;
  }

  static bool _isPathInside(Directory root, File candidate) {
    final normalizedRoot = p.normalize(p.absolute(root.path));
    final normalizedCandidate = p.normalize(p.absolute(candidate.path));
    if (normalizedRoot == normalizedCandidate) return false;
    final relative = p.relative(normalizedCandidate, from: normalizedRoot);
    return relative != '..' &&
        !relative.startsWith('..${p.separator}') &&
        !p.isAbsolute(relative);
  }

  static File _buildInstallerFile(Directory tempDir, String version) {
    if (!_isSafeVersion(version)) {
      throw const _UpdateFailure('版本信息无效，已停止自动安装');
    }

    final fileName = 'time_manager_v$version$updateAssetSuffix';
    final installerFile = File(p.join(tempDir.path, fileName));
    if (!_isPathInside(tempDir, installerFile)) {
      throw const _UpdateFailure('更新文件路径无效，已停止自动安装');
    }
    return installerFile;
  }

  static Future<void> _discardResponseBody(
    http.StreamedResponse response,
  ) async {
    await response.stream.take(_maxDiscardBytes).drain<void>();
  }

  static Future<http.StreamedResponse> _sendGetFollowingRedirects(
    http.Client client,
    Uri uri, {
    required Map<String, String> headers,
    int maxRedirects = _maxRedirects,
  }) async {
    if (!_isAllowedDownloadUri(uri)) {
      throw const _UpdateFailure('更新下载地址不受信任，已停止自动安装');
    }

    var currentUri = uri;
    var currentHeaders = Map<String, String>.from(headers);
    var usedGiteeCdnRedirect = false;

    for (var redirectCount = 0;
        redirectCount <= maxRedirects;
        redirectCount++) {
      final request = http.Request('GET', currentUri)
        ..followRedirects = false
        ..headers.addAll(currentHeaders);
      final response = await client.send(request);

      if (!_isRedirectStatus(response.statusCode)) {
        return response;
      }

      final location = response.headers['location'];
      // 消费响应体再继续，避免 HTTP 连接复用导致请求污染
      await _discardResponseBody(response);
      if (location == null || location.isEmpty) {
        return response;
      }

      final nextUri = _resolveRedirectUri(currentUri, location);
      final isAllowedGiteeUri = _isAllowedDownloadUri(nextUri);
      final isAllowedGiteeCdnRedirect = !usedGiteeCdnRedirect &&
          currentUri.host.toLowerCase() == 'gitee.com' &&
          _isAllowedGiteeCdnUri(nextUri);
      if (!isAllowedGiteeUri && !isAllowedGiteeCdnRedirect) {
        throw const _UpdateFailure('更新重定向地址不受信任，已停止自动安装');
      }
      if (isAllowedGiteeCdnRedirect) usedGiteeCdnRedirect = true;
      // 跨主机重定向：移除 Authorization，防止 token 泄露给第三方
      if (nextUri.host != currentUri.host &&
          currentHeaders.containsKey('Authorization')) {
        currentHeaders = Map<String, String>.from(currentHeaders)
          ..remove('Authorization');
      }
      currentUri = nextUri;
    }

    throw const _UpdateFailure('更新重定向次数过多，已停止自动安装');
  }

  static Future<String?> _fetchSha256Manifest(
    http.Client client,
    Uri uri,
    String expectedAssetName,
  ) async {
    try {
      final response = await _sendGetFollowingRedirects(
        client,
        uri,
        headers: _downloadHeaders,
      ).timeout(_checkTimeout);

      if (response.statusCode != HttpStatus.ok) {
        final statusCode = response.statusCode;
        await _discardResponseBody(response);
        AppLogService.instance.warning(
          '发布摘要资产下载失败（HTTP $statusCode）',
          source: 'update',
        );
        return null;
      }

      final contentBytes = <int>[];
      var received = 0;
      await for (final chunk in response.stream.timeout(_checkTimeout)) {
        if (chunk.length > _maxChecksumMetadataBytes - received) {
          AppLogService.instance.warning(
            '发布摘要资产超过大小限制，自动安装不可用',
            source: 'update',
          );
          return null;
        }
        contentBytes.addAll(chunk);
        received += chunk.length;
      }

      final content = utf8.decode(contentBytes, allowMalformed: false);
      final digest = _parseSha256Manifest(content, expectedAssetName);
      if (digest == null) {
        AppLogService.instance.warning(
          '发布摘要资产格式无效，自动安装不可用：${uri.pathSegments.last}',
          source: 'update',
        );
      }
      return digest;
    } catch (e, stackTrace) {
      AppLogService.instance.warning(
        '读取发布 SHA-256 摘要失败，当前仅可手动下载',
        source: 'update',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Check whether Gitee has published a newer release.
  static Future<UpdateCheckResult> checkForUpdate() async {
    _lastCheckedUpdate = null;
    for (int i = 0; i <= _maxRetries; i++) {
      try {
        debugPrint('检查更新: 请求 Gitee API... (尝试 ${i + 1})');
        final response = await http
            .get(
              Uri.parse(
                  'https://gitee.com/api/v5/repos/$_owner/$_repo/releases/latest'),
              headers: _headers,
            )
            .timeout(_checkTimeout);

        debugPrint('检查更新: HTTP ${response.statusCode}');
        if (response.statusCode != 200) {
          if (i < _maxRetries) {
            await Future.delayed(const Duration(seconds: 1));
            continue;
          }
          if (response.statusCode == 404) {
            AppLogService.instance.warning(
              '暂无可用发布版本',
              source: 'update',
            );
            return const UpdateCheckResult(error: '暂无发布版本');
          }
          if (response.statusCode == 401 || response.statusCode == 403) {
            AppLogService.instance.error(
              '更新接口认证失败（HTTP ${response.statusCode}）',
              source: 'update',
            );
            return const UpdateCheckResult(
                error: '更新接口认证失败，请检查 Gitee Token 和仓库权限');
          }
          AppLogService.instance.error(
            '更新接口返回错误（HTTP ${response.statusCode}）',
            source: 'update',
          );
          return UpdateCheckResult(error: '服务器返回错误 (${response.statusCode})');
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tagName = data['tag_name'] as String? ?? '';
        final body = data['body'] as String? ?? '';
        debugPrint('检查更新: 最新版本 tag=$tagName');

        if (!_isSafeVersion(tagName)) {
          AppLogService.instance.error(
            '发布版本号格式不受支持，已停止自动更新',
            source: 'update',
          );
          return const UpdateCheckResult(error: '版本信息无效，无法自动更新');
        }

        final String assetSuffix = updateAssetSuffix;
        String? installUrl;
        String? assetSha256;
        String? installerAssetName;
        final assets = data['assets'] is List<dynamic>
            ? data['assets'] as List<dynamic>
            : const <dynamic>[];
        debugPrint('检查更新: assets 数量=${assets.length}');
        for (final rawAsset in assets) {
          if (rawAsset is! Map) continue;
          final asset = Map<String, dynamic>.from(rawAsset);
          final name = _readString(asset['name']) ?? '';
          debugPrint('检查更新: asset=$name');
          if (_isSafeAssetName(name, assetSuffix)) {
            final allowedUri = _assetDownloadUri(asset);
            if (allowedUri == null) {
              AppLogService.instance.warning(
                '发布资产下载地址不受信任，已跳过：$name',
                source: 'update',
              );
              continue;
            }
            installUrl = allowedUri.toString();
            installerAssetName = name;
            assetSha256 = _extractSha256(asset);
            break;
          }
        }

        if (installUrl == null || installUrl.isEmpty) {
          AppLogService.instance.warning(
            '发布版本未找到可信的可下载安装包',
            source: 'update',
          );
          return const UpdateCheckResult(error: '未找到可信的可下载安装包');
        }

        final currentVersion = await _getCurrentVersion();
        debugPrint('检查更新: 当前版本=$currentVersion, 最新版本=$tagName');
        final isNewer = _isNewerVersion(tagName, currentVersion);

        if (!isNewer) {
          return const UpdateCheckResult();
        }

        if (assetSha256 == null && installerAssetName != null) {
          final checksumAssetName = '$installerAssetName$_checksumAssetSuffix';
          Map<String, dynamic>? checksumAsset;
          for (final rawAsset in assets) {
            if (rawAsset is! Map) continue;
            final candidate = Map<String, dynamic>.from(rawAsset);
            if (_readString(candidate['name']) == checksumAssetName) {
              checksumAsset = candidate;
              break;
            }
          }

          final checksumUri =
              checksumAsset == null ? null : _assetDownloadUri(checksumAsset);
          if (checksumUri != null) {
            final metadataClient = http.Client();
            try {
              assetSha256 = await _fetchSha256Manifest(
                metadataClient,
                checksumUri,
                installerAssetName,
              );
            } finally {
              metadataClient.close();
            }
          } else if (checksumAsset != null) {
            AppLogService.instance.warning(
              '发布摘要资产下载地址不受信任，自动安装不可用：$checksumAssetName',
              source: 'update',
            );
          }
        }

        if (assetSha256 == null) {
          AppLogService.instance.warning(
            '发布资产未提供可信 SHA-256 摘要，当前仅可手动下载；请上传同名 .sha256 发布资产',
            source: 'update',
          );
        }

        final updateInfo = UpdateInfo(
          version: tagName,
          downloadUrl: installUrl,
          releaseNotes: body,
          sha256: assetSha256,
        );
        _lastCheckedUpdate = updateInfo;
        return UpdateCheckResult(info: updateInfo);
      } on TimeoutException catch (e, stackTrace) {
        debugPrint('检查更新超时: $e');
        AppLogService.instance.warning(
          '检查更新超时',
          source: 'update',
          error: e,
          stackTrace: stackTrace,
        );
        if (i < _maxRetries) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return const UpdateCheckResult(error: '网络超时，请检查网络连接后重试');
      } catch (e, st) {
        debugPrint('检查更新失败: $e');
        debugPrint('堆栈: $st');
        AppLogService.instance.error(
          '检查更新失败',
          source: 'update',
          error: e,
          stackTrace: st,
        );
        if (i < _maxRetries) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return UpdateCheckResult(error: '检查更新失败: $e');
      }
    }

    return const UpdateCheckResult(error: '检查更新失败');
  }

  static Future<String> _getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  static bool _isNewerVersion(String newVersion, String currentVersion) {
    return _compareVersions(newVersion, currentVersion) > 0;
  }

  /// 归一化版本号：去前导 v 和 +build 元数据，但保留预发布后缀。
  static String _normalizeVersion(String version) {
    var normalized = version.trim();
    if (normalized.startsWith('v')) {
      normalized = normalized.substring(1);
    }
    final buildIndex = normalized.indexOf('+');
    if (buildIndex >= 0) {
      normalized = normalized.substring(0, buildIndex);
    }
    return normalized;
  }

  static int _compareVersions(String left, String right) {
    final leftParts = _parseVersionForComparison(left);
    final rightParts = _parseVersionForComparison(right);

    final coreLength = leftParts.core.length > rightParts.core.length
        ? leftParts.core.length
        : rightParts.core.length;
    for (var i = 0; i < coreLength; i++) {
      final leftNumber = i < leftParts.core.length ? leftParts.core[i] : 0;
      final rightNumber = i < rightParts.core.length ? rightParts.core[i] : 0;
      if (leftNumber != rightNumber) {
        return leftNumber.compareTo(rightNumber);
      }
    }

    final leftPreRelease = leftParts.preRelease;
    final rightPreRelease = rightParts.preRelease;
    if (leftPreRelease.isEmpty && rightPreRelease.isEmpty) return 0;
    if (leftPreRelease.isEmpty) return 1;
    if (rightPreRelease.isEmpty) return -1;

    final identifierLength = leftPreRelease.length > rightPreRelease.length
        ? leftPreRelease.length
        : rightPreRelease.length;
    for (var i = 0; i < identifierLength; i++) {
      if (i >= leftPreRelease.length) return -1;
      if (i >= rightPreRelease.length) return 1;

      final leftIdentifier = leftPreRelease[i];
      final rightIdentifier = rightPreRelease[i];
      if (leftIdentifier == rightIdentifier) continue;

      final leftNumber = int.tryParse(leftIdentifier);
      final rightNumber = int.tryParse(rightIdentifier);
      if (leftNumber != null && rightNumber != null) {
        return leftNumber.compareTo(rightNumber);
      }
      if (leftNumber != null) return -1;
      if (rightNumber != null) return 1;
      return leftIdentifier.compareTo(rightIdentifier);
    }
    return 0;
  }

  static _ParsedVersion _parseVersionForComparison(String version) {
    final normalized = _normalizeVersion(version);
    final separatorIndex = normalized.indexOf('-');
    final coreText = separatorIndex >= 0
        ? normalized.substring(0, separatorIndex)
        : normalized;
    final preReleaseText =
        separatorIndex >= 0 ? normalized.substring(separatorIndex + 1) : '';
    final core = coreText
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    final preRelease =
        preReleaseText.isEmpty ? const <String>[] : preReleaseText.split('.');
    return _ParsedVersion(core: core, preRelease: preRelease);
  }

  static String _formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '$bytesPerSecond B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
  }

  static String? _expectedSha256For(String downloadUrl, String version) {
    final update = _lastCheckedUpdate;
    if (update == null ||
        update.version != version ||
        update.downloadUrl != downloadUrl) {
      return null;
    }
    return update.sha256;
  }

  static Future<void> _deleteFileIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e, st) {
      AppLogService.instance.warning(
        '清理更新临时文件失败',
        source: 'update',
        error: e,
        stackTrace: st,
      );
    }
  }

  static Future<void> _downloadToFile(
    http.Client client,
    Uri uri,
    File destination, {
    required String? expectedSha256,
    required int maxBytes,
    void Function(int receivedBytes, int? contentLength)? onProgress,
  }) async {
    if (!_isAllowedDownloadUri(uri)) {
      throw const _UpdateFailure('更新下载地址不受信任，已停止自动安装');
    }
    if (!_isValidSha256(expectedSha256)) {
      throw const _UpdateFailure(_missingChecksumMessage);
    }
    if (maxBytes <= 0) {
      throw const _UpdateFailure('更新包大小限制无效');
    }
    final expectedDigest = expectedSha256!.trim().toLowerCase();

    IOSink? sink;
    try {
      final response = await _sendGetFollowingRedirects(
        client,
        uri,
        headers: _downloadHeaders,
      ).timeout(_downloadConnectTimeout);

      if (response.statusCode != HttpStatus.ok) {
        final statusCode = response.statusCode;
        await _discardResponseBody(response);
        throw _UpdateFailure(
          '下载失败（HTTP $statusCode）',
          statusCode: statusCode,
        );
      }

      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maxBytes) {
        throw const _UpdateFailure('更新包超过允许的大小限制，已停止下载');
      }

      final digestOutput = _DigestSink();
      final digestInput = sha256.startChunkedConversion(digestOutput);
      var received = 0;
      sink = destination.openWrite();

      await for (final chunk
          in response.stream.timeout(_downloadConnectTimeout)) {
        if (chunk.isEmpty) continue;
        if (chunk.length > maxBytes - received) {
          throw const _UpdateFailure('更新包超过允许的大小限制，已停止下载');
        }

        sink.add(chunk);
        digestInput.add(chunk);
        received += chunk.length;
        onProgress?.call(received, contentLength);
      }

      digestInput.close();
      await sink.close();
      sink = null;

      final actualSha256 = digestOutput.digest?.toString();
      if (actualSha256 == null) {
        throw const _UpdateFailure('更新包完整性校验失败，已停止安装');
      }
      if (actualSha256 != expectedDigest) {
        throw const _UpdateFailure('更新包完整性校验失败，已停止安装');
      }
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {
        // 清理时保留原始下载/校验错误。
      }
      await _deleteFileIfExists(destination);
      rethrow;
    }
  }

  @visibleForTesting
  static bool isSafeVersionForTesting(String version) =>
      _isSafeVersion(version);

  @visibleForTesting
  static bool isAllowedDownloadUrlForTesting(String rawUrl) =>
      _parseAllowedDownloadUri(rawUrl) != null;

  @visibleForTesting
  static String? extractSha256ForTesting(Map<String, dynamic> asset) =>
      _extractSha256(asset);

  @visibleForTesting
  static String? parseSha256ManifestForTesting(
    String content,
    String expectedAssetName,
  ) =>
      _parseSha256Manifest(content, expectedAssetName);

  @visibleForTesting
  static String normalizeVersionForTesting(String version) =>
      _normalizeVersion(version);

  @visibleForTesting
  static int compareVersionsForTesting(String left, String right) =>
      _compareVersions(left, right);

  @visibleForTesting
  static Future<String?> fetchSha256ManifestForTesting({
    required http.Client client,
    required Uri uri,
    required String expectedAssetName,
  }) =>
      _fetchSha256Manifest(client, uri, expectedAssetName);

  @visibleForTesting
  static Future<void> downloadVerifiedFileForTesting({
    required http.Client client,
    required Uri uri,
    required File destination,
    required String? expectedSha256,
    int maxBytes = _maxDownloadBytes,
  }) {
    return _downloadToFile(
      client,
      uri,
      destination,
      expectedSha256: expectedSha256,
      maxBytes: maxBytes,
    );
  }

  /// Download the installer and start the platform-specific installer.
  static Future<void> downloadAndInstall(
    String downloadUrl,
    String version,
    BuildContext context, {
    String? expectedSha256,
  }) async {
    final progressNotifier = ValueNotifier<double>(0);
    final statusNotifier = ValueNotifier<String>('准备下载...');
    File? installerFile;
    var keepInstallerFile = false;
    var downloadingDialogShown = false;

    try {
      final downloadUri = _parseAllowedDownloadUri(downloadUrl);
      if (downloadUri == null) {
        throw const _UpdateFailure('更新下载地址不受信任，已停止自动安装');
      }

      final digest =
          (expectedSha256 ?? _expectedSha256For(downloadUrl, version))
              ?.trim()
              .toLowerCase();
      if (!_isValidSha256(digest)) {
        throw const _UpdateFailure(_missingChecksumMessage);
      }

      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => _DownloadingDialog(
            progressNotifier: progressNotifier,
            statusNotifier: statusNotifier,
          ),
        );
        downloadingDialogShown = true;
      }

      final tempDir = await getTemporaryDirectory();
      installerFile = _buildInstallerFile(tempDir, version);
      final existingType = await FileSystemEntity.type(
        installerFile.path,
        followLinks: false,
      );
      if (existingType == FileSystemEntityType.link) {
        throw const _UpdateFailure('更新临时文件路径无效，已停止自动安装');
      }

      final client = http.Client();
      try {
        final startTime = DateTime.now();
        var lastReceived = 0;
        var lastTime = startTime;
        await _downloadToFile(
          client,
          downloadUri,
          installerFile,
          expectedSha256: digest!,
          maxBytes: _maxDownloadBytes,
          onProgress: (received, contentLength) {
            final now = DateTime.now();
            final elapsed = now.difference(lastTime).inMilliseconds;
            if (elapsed < 500) return;

            final speed = (received - lastReceived) * 1000 ~/ elapsed;
            final speedStr = _formatSpeed(speed);
            if (contentLength != null && contentLength > 0) {
              progressNotifier.value = received / contentLength;
              statusNotifier.value = '下载中 $speedStr';
            } else {
              statusNotifier.value = '下载中 ${received ~/ 1024}KB  $speedStr';
            }
            lastReceived = received;
            lastTime = now;
          },
        );

        debugPrint('下载并校验完成: ${installerFile.path}');

        statusNotifier.value = '正在启动安装...';
        progressNotifier.value = 1.0;

        await Future.delayed(const Duration(milliseconds: 500));

        if (downloadingDialogShown && context.mounted) {
          Navigator.pop(context);
          downloadingDialogShown = false;
        }

        if (Platform.isWindows) {
          final launched = await _launchWindowsInstaller(installerFile.path);
          if (!launched) {
            throw const _UpdateFailure('无法启动 Windows 安装程序');
          }
          keepInstallerFile = true;
        } else if (Platform.isMacOS) {
          final uri = Uri.file(installerFile.path);
          if (!await canLaunchUrl(uri) ||
              !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            throw const _UpdateFailure('无法打开 macOS 安装包');
          }
          keepInstallerFile = true;
        } else {
          final channel = MethodChannel('com.example.time_manager/install_apk');
          var launched = false;
          try {
            debugPrint('尝试通过 MethodChannel 安装 APK...');
            await channel
                .invokeMethod('installApk', {'path': installerFile.path});
            debugPrint('MethodChannel 安装成功');
            launched = true;
          } catch (e, stackTrace) {
            debugPrint('MethodChannel 失败: $e，降级到 url_launcher');
            AppLogService.instance.warning(
              '安装器通道失败，尝试备用方式',
              source: 'update',
              error: e,
              stackTrace: stackTrace,
            );
            final uri = Uri.file(installerFile.path);
            if (await canLaunchUrl(uri) &&
                await launchUrl(uri, mode: LaunchMode.externalApplication)) {
              launched = true;
            }
          }
          if (!launched) {
            throw const _UpdateFailure('无法打开安装程序');
          }
          keepInstallerFile = true;
        }
      } finally {
        client.close();
      }
    } on TimeoutException catch (e) {
      debugPrint('下载超时: $e');
      AppLogService.instance.error(
        '下载安装超时',
        source: 'update',
        error: e,
      );
      if (context.mounted) {
        if (downloadingDialogShown) Navigator.pop(context);
        _showDownloadFailedDialog(context, version, null);
      }
    } catch (e, stackTrace) {
      debugPrint('下载安装失败: $e');
      AppLogService.instance.error(
        '下载安装失败',
        source: 'update',
        error: e,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        if (downloadingDialogShown) Navigator.pop(context);
        final failure = e is _UpdateFailure ? e : null;
        _showDownloadFailedDialog(
          context,
          version,
          failure?.statusCode,
          message: failure?.message,
        );
      }
    } finally {
      if (!keepInstallerFile && installerFile != null) {
        await _deleteFileIfExists(installerFile);
      }
      progressNotifier.dispose();
      statusNotifier.dispose();
    }
  }

  /// Windows：通过 Explorer 的参数列表启动安装器，避免拼接 shell 命令。
  static Future<bool> _launchWindowsInstaller(String installerPath) async {
    try {
      debugPrint('启动 Windows 安装程序: $installerPath');
      await Process.start(
        'explorer.exe',
        [installerPath],
        mode: ProcessStartMode.detached,
      );
      debugPrint('Windows 安装程序已启动');
      return true;
    } catch (e, st) {
      debugPrint('启动安装程序失败: $e');
      debugPrint('堆栈: $st');
      AppLogService.instance.error(
        '启动安装程序失败',
        source: 'update',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  static Future<bool> openReleasePage(String version) async {
    final safeTag = _isSafeVersion(version) ? version : 'latest';
    final releasePageUrl = Uri.https(
      'gitee.com',
      '/$_owner/$_repo/releases/tag/$safeTag',
    );
    if (!await canLaunchUrl(releasePageUrl)) return false;
    return launchUrl(
      releasePageUrl,
      mode: LaunchMode.externalApplication,
    );
  }

  static void _showDownloadFailedDialog(
    BuildContext context,
    String version,
    int? statusCode, {
    String? message,
  }) {
    final displayMessage = message ??
        (statusCode == 401 || statusCode == 403
            ? '下载被拒绝，通常是私有仓库权限不足，或者 release 资产需要登录后访问。'
            : '下载失败，你可以先打开发布页手动下载，或稍后重试。');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载失败'),
        content: Text(displayMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await openReleasePage(version);
            },
            child: const Text('打开发布页'),
          ),
        ],
      ),
    );
  }
}

class _DownloadingDialog extends StatelessWidget {
  final ValueNotifier<double> progressNotifier;
  final ValueNotifier<String> statusNotifier;

  const _DownloadingDialog({
    required this.progressNotifier,
    required this.statusNotifier,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (context, progress, child) {
              return CircularProgressIndicator(
                value: progress > 0 ? progress : null,
                strokeWidth: 3,
              );
            },
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<String>(
            valueListenable: statusNotifier,
            builder: (context, status, child) {
              return Text(
                status,
                style: const TextStyle(fontSize: 14),
              );
            },
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (context, progress, child) {
              if (progress <= 0) return const SizedBox.shrink();
              return Text(
                '${(progress * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ParsedVersion {
  final List<int> core;
  final List<String> preRelease;

  const _ParsedVersion({required this.core, required this.preRelease});
}

class _UpdateFailure implements Exception {
  final String message;
  final int? statusCode;

  const _UpdateFailure(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest value) {
    digest = value;
  }

  @override
  void close() {}
}
