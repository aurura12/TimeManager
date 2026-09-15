import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/remote_repo_config.dart';
import 'contents_api_common.dart';
import 'gitee_contents_api.dart';
import 'check_in_photo_resource.dart';

class _PhotoResponseTooLarge implements Exception {}

class CheckInGiteePullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const CheckInGiteePullResult._(
      {required this.success,
      required this.notFound,
      this.content,
      this.sha,
      this.error});

  factory CheckInGiteePullResult.success(String content, String sha) {
    return CheckInGiteePullResult._(
        success: true, notFound: false, content: content, sha: sha);
  }

  factory CheckInGiteePullResult.notFound() {
    return const CheckInGiteePullResult._(success: false, notFound: true);
  }

  factory CheckInGiteePullResult.error(String message) {
    return CheckInGiteePullResult._(
        success: false, notFound: false, error: message);
  }
}

class CheckInGiteePushResult {
  final bool success;
  final bool created;
  final String? error;

  const CheckInGiteePushResult._(
      {required this.success, required this.created, this.error});

  factory CheckInGiteePushResult.success({required bool created}) {
    return CheckInGiteePushResult._(success: true, created: created);
  }

  factory CheckInGiteePushResult.error(String message) {
    return CheckInGiteePushResult._(
        success: false, created: false, error: message);
  }
}

class CheckInGiteeBinaryPullResult {
  final bool success;
  final bool notFound;
  final Uint8List? bytes;
  final String? error;

  const CheckInGiteeBinaryPullResult._(
      {required this.success, required this.notFound, this.bytes, this.error});

  factory CheckInGiteeBinaryPullResult.success(Uint8List bytes) {
    return CheckInGiteeBinaryPullResult._(
        success: true, notFound: false, bytes: bytes);
  }

  factory CheckInGiteeBinaryPullResult.notFound() {
    return const CheckInGiteeBinaryPullResult._(success: false, notFound: true);
  }

  factory CheckInGiteeBinaryPullResult.error(String message) {
    return CheckInGiteeBinaryPullResult._(
        success: false, notFound: false, error: message);
  }
}

class CheckInGiteeDeleteResult {
  final bool success;
  final String? error;

  const CheckInGiteeDeleteResult._({required this.success, this.error});

  factory CheckInGiteeDeleteResult.success() {
    return const CheckInGiteeDeleteResult._(success: true);
  }

  factory CheckInGiteeDeleteResult.error(String message) {
    return CheckInGiteeDeleteResult._(success: false, error: message);
  }
}

/// Gitee 打卡同步服务。
class CheckInGiteeService {
  static const _api = GiteeContentsApi(
    owner: RemoteRepoConfig.giteeOwner,
    repo: RemoteRepoConfig.giteeRepo,
  );

  static Future<CheckInGiteePullResult> pullText({
    required String token,
    required String path,
  }) async {
    final result = await _api.pullText(token: token, path: path);
    if (result.success) {
      return CheckInGiteePullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return CheckInGiteePullResult.notFound();
    return CheckInGiteePullResult.error(result.error ?? '拉取失败');
  }

  static Future<CheckInGiteeBinaryPullResult> pullBinary({
    required String token,
    required String path,
    http.Client? client,
  }) async {
    final normalizedPath = CheckInPhotoResource.normalizePath(path);
    if (normalizedPath == null) {
      return CheckInGiteeBinaryPullResult.error('照片路径无效');
    }

    final requestClient = client ?? http.Client();
    try {
      final streamed = await requestWithRetry(
        () => requestClient.send(
          http.Request(
            'GET',
            _api.contentsUri(normalizedPath, token: token),
          )..headers.addAll(_api.headers(token)),
        ),
      );

      if (streamed.contentLength != null &&
          streamed.contentLength! >
              CheckInPhotoResource.maxRemoteResponseBytes) {
        await streamed.stream.listen((_) {}).cancel();
        return CheckInGiteeBinaryPullResult.error('远端图片响应过大');
      }

      final bodyBytes = await _readLimitedResponse(
        streamed,
        maxBytes: CheckInPhotoResource.maxRemoteResponseBytes,
      );
      final res = http.Response.bytes(
        bodyBytes,
        streamed.statusCode,
        headers: streamed.headers,
        request: streamed.request,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
      );
      if (res.statusCode == 404) return CheckInGiteeBinaryPullResult.notFound();
      if (res.statusCode != 200) {
        return CheckInGiteeBinaryPullResult.error(extractErrorMessage(res));
      }

      final body = json.decode(res.body);
      if (body is! Map) {
        return CheckInGiteeBinaryPullResult.error('远端图片内容无效');
      }
      final rawContent = body['content']?.toString();
      if (rawContent == null) {
        return CheckInGiteeBinaryPullResult.error('远端图片内容无效');
      }
      final bytes = base64Decode(normalizeBase64(rawContent));
      final validationError = await CheckInPhotoResource.validateBytes(bytes);
      if (validationError != null) {
        return CheckInGiteeBinaryPullResult.error(validationError);
      }
      return CheckInGiteeBinaryPullResult.success(bytes);
    } on _PhotoResponseTooLarge {
      return CheckInGiteeBinaryPullResult.error('远端图片响应过大');
    } catch (e) {
      return CheckInGiteeBinaryPullResult.error('拉取图片失败');
    } finally {
      if (client == null) requestClient.close();
    }
  }

  static Future<Uint8List> _readLimitedResponse(
    http.StreamedResponse response, {
    required int maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response.stream) {
      total += chunk.length;
      if (total > maxBytes) throw _PhotoResponseTooLarge();
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// 推送打卡文档（文本）。
  ///
  /// [expectedSha] / [expectNotFound] 来自本次"先拉取再合并"的那次读取，用于
  /// 乐观并发控制：读取之后远端若被别的设备改过，服务端会拒绝写入。
  /// 直接委托给 [GiteeContentsApi.pushText]，避免在这里重复实现同一套读写逻辑。
  static Future<CheckInGiteePushResult> pushText({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
    String? expectedSha,
    bool expectNotFound = false,
  }) async {
    final result = await _api.pushText(
      token: token,
      path: path,
      content: content,
      commitMessage: commitMessage,
      expectedSha: expectedSha,
      expectNotFound: expectNotFound,
    );
    if (result.success) {
      return CheckInGiteePushResult.success(created: result.created);
    }
    return CheckInGiteePushResult.error(result.error ?? '推送失败');
  }

  static Future<CheckInGiteePushResult> pushBinary({
    required String token,
    required String path,
    required Uint8List bytes,
    required String commitMessage,
    bool skipGetSha = false,
    http.Client? client,
  }) async {
    final normalizedPath = CheckInPhotoResource.normalizePath(path);
    if (normalizedPath == null) {
      return CheckInGiteePushResult.error('照片路径无效');
    }
    final validationError = await CheckInPhotoResource.validateBytes(bytes);
    if (validationError != null) {
      return CheckInGiteePushResult.error(validationError);
    }

    return _pushBytes(
      token: token,
      path: normalizedPath,
      bytes: bytes,
      commitMessage: commitMessage,
      skipGetSha: skipGetSha,
      client: client,
    );
  }

  static Future<CheckInGiteePushResult> _pushBytes({
    required String token,
    required String path,
    required List<int> bytes,
    required String commitMessage,
    bool skipGetSha = false,
    http.Client? client,
  }) async {
    try {
      String? sha;
      if (!skipGetSha) {
        final head = await requestWithRetry(
          () =>
              client?.get(
                _api.contentsUri(path, token: token),
                headers: _api.headers(token),
              ) ??
              http.get(
                _api.contentsUri(path, token: token),
                headers: _api.headers(token),
              ),
        );
        if (head.statusCode == 200) {
          final body = json.decode(head.body);
          if (body is Map<String, dynamic>) {
            sha = body['sha']?.toString();
          }
        } else if (head.statusCode != 404) {
          return CheckInGiteePushResult.error(extractErrorMessage(head));
        }
      }

      final payload = <String, dynamic>{
        'message': commitMessage,
        'content': base64Encode(bytes),
      };
      if (sha != null) payload['sha'] = sha;

      // Gitee: 新文件用 POST，更新用 PUT
      final res = await requestWithRetry(
        () => sha == null
            ? client?.post(
                  _api.contentsUri(path, token: token),
                  headers: _api.headers(token),
                  body: json.encode(payload),
                ) ??
                http.post(
                  _api.contentsUri(path, token: token),
                  headers: _api.headers(token),
                  body: json.encode(payload),
                )
            : client?.put(
                  _api.contentsUri(path, token: token),
                  headers: _api.headers(token),
                  body: json.encode(payload),
                ) ??
                http.put(
                  _api.contentsUri(path, token: token),
                  headers: _api.headers(token),
                  body: json.encode(payload),
                ),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return CheckInGiteePushResult.success(created: res.statusCode == 201);
      }
      return CheckInGiteePushResult.error(extractErrorMessage(res));
    } catch (e) {
      return CheckInGiteePushResult.error('推送失败: $e');
    }
  }

  static Future<CheckInGiteeDeleteResult> deleteFile({
    required String token,
    required String path,
    required String commitMessage,
    http.Client? client,
  }) async {
    final normalizedPath = CheckInPhotoResource.normalizePath(path);
    if (normalizedPath == null) {
      return CheckInGiteeDeleteResult.error('照片路径无效');
    }

    try {
      final head = await requestWithRetry(
        () =>
            client?.get(
              _api.contentsUri(normalizedPath, token: token),
              headers: _api.headers(token),
            ) ??
            http.get(
              _api.contentsUri(normalizedPath, token: token),
              headers: _api.headers(token),
            ),
      );
      if (head.statusCode == 404) {
        return CheckInGiteeDeleteResult.success();
      }
      if (head.statusCode != 200) {
        return CheckInGiteeDeleteResult.error(extractErrorMessage(head));
      }
      final body = json.decode(head.body);
      if (body is! Map<String, dynamic>) {
        return CheckInGiteeDeleteResult.success();
      }
      final sha = body['sha']?.toString();
      if (sha == null) {
        return CheckInGiteeDeleteResult.error('无法获取文件 sha');
      }

      final payload = json.encode({
        'message': commitMessage,
        'sha': sha,
      });
      final res = await requestWithRetry(
        () =>
            client?.delete(
              _api.contentsUri(normalizedPath, token: token),
              headers: _api.headers(token),
              body: payload,
            ) ??
            http.delete(
              _api.contentsUri(normalizedPath, token: token),
              headers: _api.headers(token),
              body: payload,
            ),
      );
      if (res.statusCode == 200 || res.statusCode == 204) {
        return CheckInGiteeDeleteResult.success();
      }
      return CheckInGiteeDeleteResult.error(extractErrorMessage(res));
    } catch (e) {
      return CheckInGiteeDeleteResult.error('删除文件失败: $e');
    }
  }
}
