import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class CheckInPullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const CheckInPullResult._({
    required this.success,
    required this.notFound,
    this.content,
    this.sha,
    this.error,
  });

  factory CheckInPullResult.success(String content, String sha) {
    return CheckInPullResult._(
      success: true,
      notFound: false,
      content: content,
      sha: sha,
    );
  }

  factory CheckInPullResult.notFound() {
    return const CheckInPullResult._(success: false, notFound: true);
  }

  factory CheckInPullResult.error(String message) {
    return CheckInPullResult._(success: false, notFound: false, error: message);
  }
}

class CheckInPushResult {
  final bool success;
  final bool created;
  final String? error;

  const CheckInPushResult._({
    required this.success,
    required this.created,
    this.error,
  });

  factory CheckInPushResult.success({required bool created}) {
    return CheckInPushResult._(success: true, created: created);
  }

  factory CheckInPushResult.error(String message) {
    return CheckInPushResult._(success: false, created: false, error: message);
  }
}

class CheckInBinaryPullResult {
  final bool success;
  final bool notFound;
  final Uint8List? bytes;
  final String? error;

  const CheckInBinaryPullResult._({
    required this.success,
    required this.notFound,
    this.bytes,
    this.error,
  });

  factory CheckInBinaryPullResult.success(Uint8List bytes) {
    return CheckInBinaryPullResult._(
      success: true,
      notFound: false,
      bytes: bytes,
    );
  }

  factory CheckInBinaryPullResult.notFound() {
    return const CheckInBinaryPullResult._(success: false, notFound: true);
  }

  factory CheckInBinaryPullResult.error(String message) {
    return CheckInBinaryPullResult._(
      success: false,
      notFound: false,
      error: message,
    );
  }
}

class CheckInDeleteResult {
  final bool success;
  final String? error;

  const CheckInDeleteResult._({required this.success, this.error});

  factory CheckInDeleteResult.success() {
    return const CheckInDeleteResult._(success: true);
  }

  factory CheckInDeleteResult.error(String message) {
    return CheckInDeleteResult._(success: false, error: message);
  }
}

/// 打卡 GitHub 同步（与日记/出行共用 love_diary 仓库）
class CheckInGitHubService {
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

  static Future<CheckInPullResult> pullText({
    required String token,
    required String path,
  }) async {
    try {
      final res = await http.get(_contentsUri(path), headers: _headers(token));
      if (res.statusCode == 404) return CheckInPullResult.notFound();
      if (res.statusCode != 200) {
        return CheckInPullResult.error(_extractErrorMessage(res));
      }

      final map = json.decode(res.body) as Map<String, dynamic>;
      final rawContent = map['content']?.toString();
      final sha = map['sha']?.toString();
      if (rawContent == null || sha == null) {
        return CheckInPullResult.error('远端文件内容无效');
      }
      final decoded = utf8.decode(base64Decode(_normalizeBase64(rawContent)));
      return CheckInPullResult.success(decoded, sha);
    } catch (e) {
      return CheckInPullResult.error('拉取失败: $e');
    }
  }

  static Future<CheckInBinaryPullResult> pullBinary({
    required String token,
    required String path,
  }) async {
    try {
      final res = await http.get(_contentsUri(path), headers: _headers(token));
      if (res.statusCode == 404) return CheckInBinaryPullResult.notFound();
      if (res.statusCode != 200) {
        return CheckInBinaryPullResult.error(_extractErrorMessage(res));
      }

      final map = json.decode(res.body) as Map<String, dynamic>;
      final rawContent = map['content']?.toString();
      if (rawContent == null) {
        return CheckInBinaryPullResult.error('远端图片内容无效');
      }
      return CheckInBinaryPullResult.success(
        base64Decode(_normalizeBase64(rawContent)),
      );
    } catch (e) {
      return CheckInBinaryPullResult.error('拉取图片失败: $e');
    }
  }

  static Future<CheckInPushResult> pushText({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
  }) async {
    return _pushBytes(
      token: token,
      path: path,
      bytes: utf8.encode(content),
      commitMessage: commitMessage,
    );
  }

  static Future<CheckInPushResult> pushBinary({
    required String token,
    required String path,
    required Uint8List bytes,
    required String commitMessage,
  }) async {
    return _pushBytes(
      token: token,
      path: path,
      bytes: bytes,
      commitMessage: commitMessage,
    );
  }

  static Future<CheckInPushResult> _pushBytes({
    required String token,
    required String path,
    required List<int> bytes,
    required String commitMessage,
  }) async {
    try {
      String? sha;
      final head = await http.get(_contentsUri(path), headers: _headers(token));
      if (head.statusCode == 200) {
        final map = json.decode(head.body) as Map<String, dynamic>;
        sha = map['sha']?.toString();
      } else if (head.statusCode != 404) {
        return CheckInPushResult.error(_extractErrorMessage(head));
      }

      final payload = <String, dynamic>{
        'message': commitMessage,
        'content': base64Encode(bytes),
      };
      if (sha != null) payload['sha'] = sha;

      final res = await http.put(
        _contentsUri(path),
        headers: _headers(token),
        body: json.encode(payload),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return CheckInPushResult.success(created: res.statusCode == 201);
      }
      return CheckInPushResult.error(_extractErrorMessage(res));
    } catch (e) {
      return CheckInPushResult.error('推送失败: $e');
    }
  }

  static Future<CheckInDeleteResult> deleteFile({
    required String token,
    required String path,
  }) async {
    try {
      final head = await http.get(_contentsUri(path), headers: _headers(token));
      if (head.statusCode == 404) {
        return CheckInDeleteResult.success();
      }
      if (head.statusCode != 200) {
        return CheckInDeleteResult.error(_extractErrorMessage(head));
      }
      final map = json.decode(head.body) as Map<String, dynamic>;
      final sha = map['sha']?.toString();
      if (sha == null) {
        return CheckInDeleteResult.error('无法获取文件 sha');
      }

      final payload = json.encode({
        'message': 'check-in: delete photo $path',
        'sha': sha,
      });
      final res = await http.delete(
        _contentsUri(path),
        headers: _headers(token),
        body: payload,
      );
      if (res.statusCode == 200 || res.statusCode == 204) {
        return CheckInDeleteResult.success();
      }
      return CheckInDeleteResult.error(_extractErrorMessage(res));
    } catch (e) {
      return CheckInDeleteResult.error('删除文件失败: $e');
    }
  }
}
