import 'dart:convert';

import 'package:http/http.dart' as http;

import 'github_contents_api.dart';
import '../config/remote_repo_config.dart';
import '../models/remote_sync_platform.dart';
import 'remote_sync_settings.dart';

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

class DiaryListWithShaResult {
  final bool success;
  final Map<String, String> pathShaMap;
  final String? error;

  const DiaryListWithShaResult._({
    required this.success,
    required this.pathShaMap,
    this.error,
  });

  factory DiaryListWithShaResult.success(Map<String, String> pathShaMap) {
    return DiaryListWithShaResult._(success: true, pathShaMap: pathShaMap);
  }

  factory DiaryListWithShaResult.error(String message) {
    return DiaryListWithShaResult._(
      success: false,
      pathShaMap: const {},
      error: message,
    );
  }
}

class DiaryGitHubService {
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

  static bool _looksLikeDiaryMd(String path) {
    final lower = path.toLowerCase();
    if (!lower.endsWith('.md')) return false;
    final fileName = path.split('/').last;
    return fileName.startsWith('G') || fileName.startsWith('J');
  }

  static Future<DiaryPullResult> pullDiary({
    required String token,
    required String path,
  }) async {
    final api = _apiFor(await RemoteSyncSettings.loadPlatform());
    final result = await api.pullText(token: token, path: path);
    if (result.success) {
      return DiaryPullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return DiaryPullResult.notFound();
    return DiaryPullResult.error(result.error ?? '拉取失败');
  }

  static Future<DiaryPushResult> pushDiary({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
  }) async {
    final api = _apiFor(await RemoteSyncSettings.loadPlatform());
    final result = await api.pushText(
      token: token,
      path: path,
      content: content,
      commitMessage: commitMessage,
    );
    if (result.success) {
      return DiaryPushResult.success(created: result.created);
    }
    return DiaryPushResult.error(result.error ?? '推送失败');
  }

  static Future<DiaryListResult> listDiaryPaths({
    required String token,
  }) async {
    final result = await listDiaryPathsWithSha(token: token);
    if (!result.success) {
      return DiaryListResult.error(result.error ?? '读取远端日记列表失败');
    }
    final paths = result.pathShaMap.keys.toList();
    paths.sort((a, b) => b.compareTo(a));
    return DiaryListResult.success(paths);
  }

  static Future<DiaryListWithShaResult> listDiaryPathsWithSha({
    required String token,
  }) async {
    try {
      final api = _apiFor(await RemoteSyncSettings.loadPlatform());
      final res = await requestWithRetry(
        () => http.get(api.treeUri('HEAD', token: token), headers: api.headers(token)),
      );
      if (res.statusCode != 200) {
        return DiaryListWithShaResult.error(GitHubContentsApi.extractErrorMessage(res));
      }
      final map = json.decode(res.body) as Map<String, dynamic>;
      final tree = map['tree'];
      if (tree is! List) {
        return DiaryListWithShaResult.error('远端目录结构无效');
      }
      final pathShaMap = <String, String>{};
      for (final item in tree) {
        if (item is! Map) continue;
        final type = item['type']?.toString();
        final path = item['path']?.toString();
        final sha = item['sha']?.toString();
        if (type == 'blob' &&
            path != null &&
            path.isNotEmpty &&
            sha != null &&
            _looksLikeDiaryMd(path)) {
          pathShaMap[path] = sha;
        }
      }
      return DiaryListWithShaResult.success(pathShaMap);
    } catch (e) {
      return DiaryListWithShaResult.error('读取远端日记列表失败: $e');
    }
  }
}
