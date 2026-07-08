import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/remote_sync_platform.dart';

const Duration _defaultTimeout = Duration(seconds: 15);
const int _maxRetries = 2;

bool _isRetryableError(Object e) {
  return e is TimeoutException ||
      e is SocketException ||
      e is HttpException ||
      e is IOException ||
      e is HandshakeException ||
      e is TlsException;
}

Future<http.Response> requestWithRetry(
  Future<http.Response> Function() request, {
  int maxRetries = _maxRetries,
  Duration timeout = _defaultTimeout,
}) async {
  for (int i = 0; i <= maxRetries; i++) {
    try {
      return await request().timeout(timeout);
    } catch (e) {
      if (i == maxRetries || !_isRetryableError(e)) rethrow;
      await Future.delayed(const Duration(seconds: 1));
    }
  }
  throw StateError('unreachable');
}

/// Shared repository contents API helpers used by diary, travel, and check-in services.
class GitHubContentsApi {
  final String owner;
  final String repo;
  final RemoteSyncPlatform platform;

  const GitHubContentsApi.github({required this.owner, required this.repo})
      : platform = RemoteSyncPlatform.github;

  const GitHubContentsApi.gitee({required this.owner, required this.repo})
      : platform = RemoteSyncPlatform.gitee;

  bool get isGitee => platform == RemoteSyncPlatform.gitee;

  String get _baseHost => isGitee ? 'gitee.com' : 'api.github.com';
  String get _repoPrefix => isGitee ? '/api/v5/repos' : '/repos';

  Map<String, String> headers(String token) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    headers['Authorization'] = isGitee ? 'token $token' : 'Bearer $token';
    if (!isGitee) {
      headers['X-GitHub-Api-Version'] = '2022-11-28';
    }
    return headers;
  }

  Uri contentsUri(String path, {String? token}) {
    return Uri.https(
      _baseHost,
      '$_repoPrefix/$owner/$repo/contents/$path',
      isGitee && token != null && token.isNotEmpty
          ? {'access_token': token}
          : null,
    );
  }

  Uri treeUri(String ref, {bool recursive = true, String? token}) {
    return Uri.https(
      _baseHost,
      '$_repoPrefix/$owner/$repo/git/trees/$ref',
      {
        if (recursive) 'recursive': '1',
        if (isGitee && token != null && token.isNotEmpty) 'access_token': token,
      },
    );
  }

  static String normalizeBase64(String value) {
    return value.replaceAll('\n', '');
  }

  static String extractErrorMessage(http.Response response) {
    try {
      final map = json.decode(response.body) as Map<String, dynamic>;
      final message = map['message']?.toString();
      if (message != null && message.isNotEmpty) return message;
    } catch (_) {}
    return 'GitHub 请求失败（${response.statusCode}）';
  }

  /// Pull a text file from the repo. Returns (content, sha) or null if not found.
  Future<({bool success, bool notFound, String? content, String? sha, String? error})> pullText({
    required String token,
    required String path,
  }) async {
    try {
      final res = await requestWithRetry(
        () => http.get(contentsUri(path, token: token), headers: headers(token)),
      );
      if (res.statusCode == 404) {
        return (success: false, notFound: true, content: null, sha: null, error: null);
      }
      if (res.statusCode != 200) {
        return (success: false, notFound: false, content: null, sha: null, error: extractErrorMessage(res));
      }

      final body = json.decode(res.body);
      // Gitee 对不存在的文件路径可能返回目录列表 (List) 而非 404
      if (body is List) {
        return (success: false, notFound: true, content: null, sha: null, error: null);
      }
      final map = body as Map<String, dynamic>;
      final rawContent = map['content']?.toString();
      final sha = map['sha']?.toString();
      if (rawContent == null || sha == null) {
        return (success: false, notFound: false, content: null, sha: null, error: '远端文件内容无效');
      }
      final decoded = utf8.decode(base64Decode(normalizeBase64(rawContent)));
      return (success: true, notFound: false, content: decoded, sha: sha, error: null);
    } catch (e) {
      return (success: false, notFound: false, content: null, sha: null, error: '拉取失败: $e');
    }
  }

  /// Push a text file to the repo.
  Future<({bool success, bool created, String? error})> pushText({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
  }) async {
    try {
      String? sha;
      final current = await pullText(token: token, path: path);
      if (current.success) {
        sha = current.sha;
      } else if (!current.notFound) {
        return (success: false, created: false, error: current.error ?? '读取远端文件失败');
      }

      final payload = <String, dynamic>{
        'message': commitMessage,
        'content': base64Encode(utf8.encode(content)),
      };
      if (sha != null) payload['sha'] = sha;

      final res = await requestWithRetry(
        () => http.put(
          contentsUri(path, token: token),
          headers: headers(token),
          body: json.encode(payload),
        ),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return (success: true, created: res.statusCode == 201, error: null);
      }
      return (success: false, created: false, error: extractErrorMessage(res));
    } catch (e) {
      return (success: false, created: false, error: '推送失败: $e');
    }
  }
}
