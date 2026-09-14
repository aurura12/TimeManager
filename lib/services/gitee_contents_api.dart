import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contents_api_common.dart';

/// Gitee 仓库内容 API 封装。
class GiteeContentsApi {
  final String owner;
  final String repo;
  final http.Client? _client;

  const GiteeContentsApi({
    required this.owner,
    required this.repo,
    http.Client? client,
  }) : _client = client;

  String get _baseHost => 'gitee.com';
  String get _repoPrefix => '/api/v5/repos';

  Map<String, String> headers(String token) {
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': 'token $token',
    };
  }

  Future<http.Response> _get(Uri uri, String token) {
    final client = _client;
    if (client != null) return client.get(uri, headers: headers(token));
    return http.get(uri, headers: headers(token));
  }

  Future<http.Response> _post(Uri uri, String token, String body) {
    final client = _client;
    if (client != null) {
      return client.post(uri, headers: headers(token), body: body);
    }
    return http.post(uri, headers: headers(token), body: body);
  }

  Future<http.Response> _put(Uri uri, String token, String body) {
    final client = _client;
    if (client != null) {
      return client.put(uri, headers: headers(token), body: body);
    }
    return http.put(uri, headers: headers(token), body: body);
  }

  Uri contentsUri(String path, {String? token}) {
    return Uri.https(
      _baseHost,
      '$_repoPrefix/$owner/$repo/contents/$path',
    );
  }

  Uri treeUri(String ref, {bool recursive = true, String? token}) {
    return Uri.https(
      _baseHost,
      '$_repoPrefix/$owner/$repo/git/trees/$ref',
      {if (recursive) 'recursive': '1'},
    );
  }

  /// 拉取文件内容。
  Future<
      ({
        bool success,
        bool notFound,
        String? content,
        String? sha,
        String? error
      })> pullText({
    required String token,
    required String path,
  }) async {
    try {
      final res = await requestWithRetry(
        () => _get(contentsUri(path, token: token), token),
      );
      if (res.statusCode == 404) {
        return (
          success: false,
          notFound: true,
          content: null,
          sha: null,
          error: null
        );
      }
      if (res.statusCode != 200) {
        return (
          success: false,
          notFound: false,
          content: null,
          sha: null,
          error: extractErrorMessage(res)
        );
      }

      final body = json.decode(res.body);
      // Gitee 对不存在的文件可能返回目录列表而非 404
      if (body is List) {
        return (
          success: false,
          notFound: true,
          content: null,
          sha: null,
          error: null
        );
      }
      final map = body as Map<String, dynamic>;
      final rawContent = map['content']?.toString();
      final sha = map['sha']?.toString();
      if (rawContent == null || sha == null) {
        return (
          success: false,
          notFound: false,
          content: null,
          sha: null,
          error: '远端文件内容无效'
        );
      }
      final decoded = utf8.decode(base64Decode(normalizeBase64(rawContent)));
      return (
        success: true,
        notFound: false,
        content: decoded,
        sha: sha,
        error: null
      );
    } catch (e) {
      return (
        success: false,
        notFound: false,
        content: null,
        sha: null,
        error: '拉取失败: $e'
      );
    }
  }

  /// 推送文件内容。新文件用 POST，更新用 PUT。
  Future<
      ({
        bool success,
        bool created,
        String? sha,
        bool conflict,
        String? error
      })> pushText({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
    String? expectedSha,
    bool expectNotFound = false,
  }) async {
    try {
      String? sha;
      if (expectedSha != null) {
        // 调用方已经读取过该版本。把这个 sha 原样交给 PUT，让服务端在版本
        // 变化时拒绝写入，避免“先读后写”期间覆盖并发更新。
        sha = expectedSha;
      } else if (expectNotFound) {
        // 创建文件前再次确认远端仍不存在；若之后并发创建，POST 也会失败，
        // 不会转成更新请求覆盖对方内容。
        final current = await pullText(token: token, path: path);
        if (current.success) {
          return (
            success: false,
            created: false,
            sha: null,
            conflict: false,
            error: '远端文件已发生变化，请先重新拉取',
          );
        }
        if (!current.notFound) {
          return (
            success: false,
            created: false,
            sha: null,
            conflict: false,
            error: current.error ?? '读取远端文件失败',
          );
        }
      } else {
        final current = await pullText(token: token, path: path);
        if (current.success) {
          sha = current.sha;
        } else if (!current.notFound) {
          return (
            success: false,
            created: false,
            sha: null,
            conflict: false,
            error: current.error ?? '读取远端文件失败',
          );
        }
      }

      final payload = <String, dynamic>{
        'message': commitMessage,
        'content': base64Encode(utf8.encode(content)),
      };
      if (sha != null) payload['sha'] = sha;

      // Gitee: 新文件用 POST，更新用 PUT
      final res = await requestWithRetry(
        () => sha == null
            ? _post(
                contentsUri(path, token: token), token, json.encode(payload))
            : _put(
                contentsUri(path, token: token), token, json.encode(payload)),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        String? pushedSha;
        try {
          final body = json.decode(res.body);
          if (body is Map<String, dynamic>) {
            final content = body['content'];
            if (content is Map) {
              pushedSha = content['sha']?.toString();
            }
            pushedSha ??= body['sha']?.toString();
          }
        } catch (_) {
          // 某些兼容实现可能返回空响应；写入已经成功，SHA 留空即可。
        }
        return (
          success: true,
          created: res.statusCode == 201,
          sha: pushedSha,
          conflict: false,
          error: null,
        );
      }
      return (
        success: false,
        created: false,
        sha: null,
        conflict: expectedSha != null &&
            (res.statusCode == 409 ||
                res.statusCode == 412 ||
                res.statusCode == 422),
        error: extractErrorMessage(res),
      );
    } catch (e) {
      return (
        success: false,
        created: false,
        sha: null,
        conflict: false,
        error: '推送失败: $e',
      );
    }
  }
}
