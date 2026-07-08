import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'github_contents_api.dart';
import '../config/remote_repo_config.dart';
import '../models/remote_sync_platform.dart';
import 'remote_sync_settings.dart';

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
  static GitHubContentsApi _apiFor(RemoteSyncPlatform platform) {
    switch (platform) {
      case RemoteSyncPlatform.gitee:
        return GitHubContentsApi.gitee(
          owner: RemoteRepoConfig.giteeOwner,
          repo: RemoteRepoConfig.giteeRepo,
        );
      case RemoteSyncPlatform.github:
        return GitHubContentsApi.github(
          owner: RemoteRepoConfig.githubOwner,
          repo: RemoteRepoConfig.githubRepo,
        );
    }
  }

  static Future<CheckInPullResult> pullText({
    required String token,
    required String path,
  }) async {
    final api = _apiFor(await RemoteSyncSettings.loadPlatform());
    final result = await api.pullText(token: token, path: path);
    if (result.success) {
      return CheckInPullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return CheckInPullResult.notFound();
    return CheckInPullResult.error(result.error ?? '拉取失败');
  }

  static Future<CheckInBinaryPullResult> pullBinary({
    required String token,
    required String path,
  }) async {
    try {
      final api = _apiFor(await RemoteSyncSettings.loadPlatform());
      final res = await requestWithRetry(
        () => http.get(api.contentsUri(path, token: token), headers: api.headers(token)),
      );
      if (res.statusCode == 404) return CheckInBinaryPullResult.notFound();
      if (res.statusCode != 200) {
        return CheckInBinaryPullResult.error(GitHubContentsApi.extractErrorMessage(res));
      }

      final map = json.decode(res.body) as Map<String, dynamic>;
      final rawContent = map['content']?.toString();
      if (rawContent == null) {
        return CheckInBinaryPullResult.error('远端图片内容无效');
      }
      return CheckInBinaryPullResult.success(
        base64Decode(GitHubContentsApi.normalizeBase64(rawContent)),
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
    bool skipGetSha = false,
  }) async {
    return _pushBytes(
      token: token,
      path: path,
      bytes: bytes,
      commitMessage: commitMessage,
      skipGetSha: skipGetSha,
    );
  }

  static Future<CheckInPushResult> _pushBytes({
    required String token,
    required String path,
    required List<int> bytes,
    required String commitMessage,
    bool skipGetSha = false,
  }) async {
    try {
      final api = _apiFor(await RemoteSyncSettings.loadPlatform());
      String? sha;
      if (!skipGetSha) {
        final head = await requestWithRetry(
          () => http.get(api.contentsUri(path, token: token), headers: api.headers(token)),
        );
        if (head.statusCode == 200) {
          final map = json.decode(head.body) as Map<String, dynamic>;
          sha = map['sha']?.toString();
        } else if (head.statusCode != 404) {
          return CheckInPushResult.error(GitHubContentsApi.extractErrorMessage(head));
        }
      }

      final payload = <String, dynamic>{
        'message': commitMessage,
        'content': base64Encode(bytes),
      };
      if (sha != null) payload['sha'] = sha;

      final res = await requestWithRetry(
        () => http.put(
          api.contentsUri(path, token: token),
          headers: api.headers(token),
          body: json.encode(payload),
        ),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return CheckInPushResult.success(created: res.statusCode == 201);
      }
      return CheckInPushResult.error(GitHubContentsApi.extractErrorMessage(res));
    } catch (e) {
      return CheckInPushResult.error('推送失败: $e');
    }
  }

  static Future<CheckInDeleteResult> deleteFile({
    required String token,
    required String path,
  }) async {
    try {
      final api = _apiFor(await RemoteSyncSettings.loadPlatform());
      final head = await requestWithRetry(
        () => http.get(api.contentsUri(path, token: token), headers: api.headers(token)),
      );
      if (head.statusCode == 404) {
        return CheckInDeleteResult.success();
      }
      if (head.statusCode != 200) {
        return CheckInDeleteResult.error(GitHubContentsApi.extractErrorMessage(head));
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
      final res = await requestWithRetry(
        () => http.delete(
          api.contentsUri(path, token: token),
          headers: api.headers(token),
          body: payload,
        ),
      );
      if (res.statusCode == 200 || res.statusCode == 204) {
        return CheckInDeleteResult.success();
      }
      return CheckInDeleteResult.error(GitHubContentsApi.extractErrorMessage(res));
    } catch (e) {
      return CheckInDeleteResult.error('删除文件失败: $e');
    }
  }
}
