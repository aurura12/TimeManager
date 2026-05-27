import 'dart:convert';

import 'package:http/http.dart' as http;

class DiaryPullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const DiaryPullResult._({
    required this.success,
    required this.notFound,
    this.content,
    this.sha,
    this.error,
  });

  factory DiaryPullResult.success(String content, String sha) {
    return DiaryPullResult._(
      success: true,
      notFound: false,
      content: content,
      sha: sha,
    );
  }

  factory DiaryPullResult.notFound() {
    return const DiaryPullResult._(success: false, notFound: true);
  }

  factory DiaryPullResult.error(String message) {
    return DiaryPullResult._(
      success: false,
      notFound: false,
      error: message,
    );
  }
}

class DiaryPushResult {
  final bool success;
  final bool created;
  final String? error;

  const DiaryPushResult._({
    required this.success,
    required this.created,
    this.error,
  });

  factory DiaryPushResult.success({required bool created}) {
    return DiaryPushResult._(success: true, created: created);
  }

  factory DiaryPushResult.error(String message) {
    return DiaryPushResult._(
      success: false,
      created: false,
      error: message,
    );
  }
}

class DiaryListResult {
  final bool success;
  final List<String> paths;
  final String? error;

  const DiaryListResult._({
    required this.success,
    required this.paths,
    this.error,
  });

  factory DiaryListResult.success(List<String> paths) {
    return DiaryListResult._(success: true, paths: paths);
  }

  factory DiaryListResult.error(String message) {
    return DiaryListResult._(success: false, paths: const [], error: message);
  }
}

class DiaryGitHubService {
  static const String _owner = 'aurura12';
  static const String _repo = 'love_diary';
  static const String _baseHost = 'api.github.com';

  static Map<String, String> _headers(String token) {
    return {
      'Accept': 'application/vnd.github+json',
      'Authorization': 'Bearer $token',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    };
  }

  static Uri _contentsUri(String path) {
    return Uri.https(_baseHost, '/repos/$_owner/$_repo/contents/$path');
  }

  static Uri _treeUri() {
    return Uri.https(
      _baseHost,
      '/repos/$_owner/$_repo/git/trees/HEAD',
      {'recursive': '1'},
    );
  }

  static bool _looksLikeDiaryMd(String path) {
    final lower = path.toLowerCase();
    if (!lower.endsWith('.md')) return false;
    final fileName = path.split('/').last;
    return fileName.startsWith('G') || fileName.startsWith('J');
  }

  static String _normalizeBase64(String value) {
    return value.replaceAll('\n', '');
  }

  static String _extractErrorMessage(http.Response response) {
    try {
      final map = json.decode(response.body) as Map<String, dynamic>;
      final message = map['message']?.toString();
      if (message != null && message.isNotEmpty) return message;
    } catch (_) {}
    return 'GitHub 请求失败（${response.statusCode}）';
  }

  static Future<DiaryPullResult> pullDiary({
    required String token,
    required String path,
  }) async {
    try {
      final res = await http.get(_contentsUri(path), headers: _headers(token));
      if (res.statusCode == 404) {
        return DiaryPullResult.notFound();
      }
      if (res.statusCode != 200) {
        return DiaryPullResult.error(_extractErrorMessage(res));
      }

      final map = json.decode(res.body) as Map<String, dynamic>;
      final rawContent = map['content']?.toString();
      final sha = map['sha']?.toString();
      if (rawContent == null || sha == null) {
        return DiaryPullResult.error('远端文件内容无效');
      }
      final decoded = utf8.decode(base64Decode(_normalizeBase64(rawContent)));
      return DiaryPullResult.success(decoded, sha);
    } catch (e) {
      return DiaryPullResult.error('拉取失败: $e');
    }
  }

  static Future<DiaryPushResult> pushDiary({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
  }) async {
    try {
      String? sha;
      final current = await pullDiary(token: token, path: path);
      if (current.success) {
        sha = current.sha;
      } else if (!current.notFound) {
        return DiaryPushResult.error(current.error ?? '读取远端文件失败');
      }

      final payload = <String, dynamic>{
        'message': commitMessage,
        'content': base64Encode(utf8.encode(content)),
      };
      if (sha != null) {
        payload['sha'] = sha;
      }

      final res = await http.put(
        _contentsUri(path),
        headers: _headers(token),
        body: json.encode(payload),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return DiaryPushResult.success(created: res.statusCode == 201);
      }
      return DiaryPushResult.error(_extractErrorMessage(res));
    } catch (e) {
      return DiaryPushResult.error('推送失败: $e');
    }
  }

  static Future<DiaryListResult> listDiaryPaths({
    required String token,
  }) async {
    try {
      final res = await http.get(_treeUri(), headers: _headers(token));
      if (res.statusCode != 200) {
        return DiaryListResult.error(_extractErrorMessage(res));
      }
      final map = json.decode(res.body) as Map<String, dynamic>;
      final tree = map['tree'];
      if (tree is! List) {
        return DiaryListResult.error('远端目录结构无效');
      }
      final paths = <String>[];
      for (final item in tree) {
        if (item is! Map) continue;
        final type = item['type']?.toString();
        final path = item['path']?.toString();
        if (type == 'blob' &&
            path != null &&
            path.isNotEmpty &&
            _looksLikeDiaryMd(path)) {
          paths.add(path);
        }
      }
      paths.sort((a, b) => b.compareTo(a));
      return DiaryListResult.success(paths);
    } catch (e) {
      return DiaryListResult.error('读取远端日记列表失败: $e');
    }
  }
}
