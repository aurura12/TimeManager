import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contents_api_common.dart';

/// Gitee 仓库内容 API 封装。
class GiteeContentsApi {
  final String owner;
  final String repo;

  const GiteeContentsApi({required this.owner, required this.repo});

  String get _baseHost => 'gitee.com';
  String get _repoPrefix => '/api/v5/repos';

  Map<String, String> headers(String token) {
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': 'token $token',
    };
  }

  Uri contentsUri(String path, {String? token}) {
    return Uri.https(
      _baseHost,
      '$_repoPrefix/$owner/$repo/contents/$path',
      token != null && token.isNotEmpty ? {'access_token': token} : null,
    );
  }

  Uri treeUri(String ref, {bool recursive = true, String? token}) {
    return Uri.https(
      _baseHost,
      '$_repoPrefix/$owner/$repo/git/trees/$ref',
      {
        if (recursive) 'recursive': '1',
        if (token != null && token.isNotEmpty) 'access_token': token,
      },
    );
  }

  /// 拉取文件内容。
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
      // Gitee 对不存在的文件可能返回目录列表而非 404
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

  /// 推送文件内容。新文件用 POST，更新用 PUT。
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

      // Gitee: 新文件用 POST，更新用 PUT
      final res = await requestWithRetry(
        () => sha == null
            ? http.post(
                contentsUri(path, token: token),
                headers: headers(token),
                body: json.encode(payload),
              )
            : http.put(
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
