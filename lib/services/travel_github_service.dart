import 'dart:convert';

import 'package:http/http.dart' as http;

class TravelPullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const TravelPullResult._({
    required this.success,
    required this.notFound,
    this.content,
    this.sha,
    this.error,
  });

  factory TravelPullResult.success(String content, String sha) {
    return TravelPullResult._(
      success: true,
      notFound: false,
      content: content,
      sha: sha,
    );
  }

  factory TravelPullResult.notFound() {
    return const TravelPullResult._(success: false, notFound: true);
  }

  factory TravelPullResult.error(String message) {
    return TravelPullResult._(success: false, notFound: false, error: message);
  }
}

class TravelPushResult {
  final bool success;
  final bool created;
  final String? error;

  const TravelPushResult._({
    required this.success,
    required this.created,
    this.error,
  });

  factory TravelPushResult.success({required bool created}) {
    return TravelPushResult._(success: true, created: created);
  }

  factory TravelPushResult.error(String message) {
    return TravelPushResult._(success: false, created: false, error: message);
  }
}

class TravelGitHubService {
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

  static Future<TravelPullResult> pullFile({
    required String token,
    required String path,
  }) async {
    try {
      final res = await http.get(_contentsUri(path), headers: _headers(token));
      if (res.statusCode == 404) {
        return TravelPullResult.notFound();
      }
      if (res.statusCode != 200) {
        return TravelPullResult.error(_extractErrorMessage(res));
      }

      final map = json.decode(res.body) as Map<String, dynamic>;
      final rawContent = map['content']?.toString();
      final sha = map['sha']?.toString();
      if (rawContent == null || sha == null) {
        return TravelPullResult.error('远端文件内容无效');
      }
      final decoded = utf8.decode(base64Decode(_normalizeBase64(rawContent)));
      return TravelPullResult.success(decoded, sha);
    } catch (e) {
      return TravelPullResult.error('拉取失败: $e');
    }
  }

  static Future<TravelPushResult> pushFile({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
  }) async {
    try {
      String? sha;
      final current = await pullFile(token: token, path: path);
      if (current.success) {
        sha = current.sha;
      } else if (!current.notFound) {
        return TravelPushResult.error(current.error ?? '读取远端文件失败');
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
        return TravelPushResult.success(created: res.statusCode == 201);
      }
      return TravelPushResult.error(_extractErrorMessage(res));
    } catch (e) {
      return TravelPushResult.error('推送失败: $e');
    }
  }
}
