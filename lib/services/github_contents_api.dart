import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const Duration _defaultTimeout = Duration(seconds: 10);
const int _maxRetries = 1;

bool _isRetryableError(Object e) {
  return e is TimeoutException ||
      e is SocketException ||
      e is HttpException ||
      e is IOException;
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

/// Shared GitHub Contents API helpers used by diary, travel, and check-in services.
class GitHubContentsApi {
  static const String _baseHost = 'api.github.com';

  final String owner;
  final String repo;

  const GitHubContentsApi({required this.owner, required this.repo});

  Map<String, String> headers(String token) {
    return {
      'Accept': 'application/vnd.github+json',
      'Authorization': 'Bearer $token',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    };
  }

  Uri contentsUri(String path) {
    return Uri.https(_baseHost, '/repos/$owner/$repo/contents/$path');
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
        () => http.get(contentsUri(path), headers: headers(token)),
      );
      if (res.statusCode == 404) {
        return (success: false, notFound: true, content: null, sha: null, error: null);
      }
      if (res.statusCode != 200) {
        return (success: false, notFound: false, content: null, sha: null, error: extractErrorMessage(res));
      }

      final map = json.decode(res.body) as Map<String, dynamic>;
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
          contentsUri(path),
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
