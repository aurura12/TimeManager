import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/remote_repo_config.dart';
import 'contents_api_common.dart';
import 'gitee_contents_api.dart';

class DiaryGiteePullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const DiaryGiteePullResult._({required this.success, required this.notFound, this.content, this.sha, this.error});

  factory DiaryGiteePullResult.success(String content, String sha) {
    return DiaryGiteePullResult._(success: true, notFound: false, content: content, sha: sha);
  }

  factory DiaryGiteePullResult.notFound() {
    return const DiaryGiteePullResult._(success: false, notFound: true);
  }

  factory DiaryGiteePullResult.error(String message) {
    return DiaryGiteePullResult._(success: false, notFound: false, error: message);
  }
}

class DiaryGiteePushResult {
  final bool success;
  final bool created;
  final String? error;

  const DiaryGiteePushResult._({required this.success, required this.created, this.error});

  factory DiaryGiteePushResult.success({required bool created}) {
    return DiaryGiteePushResult._(success: true, created: created);
  }

  factory DiaryGiteePushResult.error(String message) {
    return DiaryGiteePushResult._(success: false, created: false, error: message);
  }
}

class DiaryGiteeListResult {
  final bool success;
  final List<String> paths;
  final String? error;

  const DiaryGiteeListResult._({required this.success, required this.paths, this.error});

  factory DiaryGiteeListResult.success(List<String> paths) {
    return DiaryGiteeListResult._(success: true, paths: paths);
  }

  factory DiaryGiteeListResult.error(String message) {
    return DiaryGiteeListResult._(success: false, paths: const [], error: message);
  }
}

class DiaryGiteeListWithShaResult {
  final bool success;
  final Map<String, String> pathShaMap;
  final String? error;

  const DiaryGiteeListWithShaResult._({required this.success, required this.pathShaMap, this.error});

  factory DiaryGiteeListWithShaResult.success(Map<String, String> pathShaMap) {
    return DiaryGiteeListWithShaResult._(success: true, pathShaMap: pathShaMap);
  }

  factory DiaryGiteeListWithShaResult.error(String message) {
    return DiaryGiteeListWithShaResult._(success: false, pathShaMap: const {}, error: message);
  }
}

/// Gitee 日记同步服务。
class DiaryGiteeService {
  static const _api = GiteeContentsApi(
    owner: RemoteRepoConfig.giteeOwner,
    repo: RemoteRepoConfig.giteeRepo,
  );

  static bool _looksLikeDiaryMd(String path) {
    final lower = path.toLowerCase();
    if (!lower.endsWith('.md')) return false;
    final fileName = path.split('/').last;
    return fileName.startsWith('G') || fileName.startsWith('J');
  }

  static Future<DiaryGiteePullResult> pullDiary({
    required String token,
    required String path,
  }) async {
    final result = await _api.pullText(token: token, path: path);
    if (result.success) {
      return DiaryGiteePullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return DiaryGiteePullResult.notFound();
    return DiaryGiteePullResult.error(result.error ?? '拉取失败');
  }

  static Future<DiaryGiteePushResult> pushDiary({
    required String token,
    required String path,
    required String content,
    required String commitMessage,
  }) async {
    final result = await _api.pushText(
      token: token,
      path: path,
      content: content,
      commitMessage: commitMessage,
    );
    if (result.success) {
      return DiaryGiteePushResult.success(created: result.created);
    }
    return DiaryGiteePushResult.error(result.error ?? '推送失败');
  }

  static Future<DiaryGiteeListResult> listDiaryPaths({
    required String token,
  }) async {
    final result = await listDiaryPathsWithSha(token: token);
    if (!result.success) {
      return DiaryGiteeListResult.error(result.error ?? '读取远端日记列表失败');
    }
    final paths = result.pathShaMap.keys.toList();
    paths.sort((a, b) => b.compareTo(a));
    return DiaryGiteeListResult.success(paths);
  }

  static Future<DiaryGiteeListWithShaResult> listDiaryPathsWithSha({
    required String token,
  }) async {
    try {
      final res = await requestWithRetry(
        () => http.get(_api.treeUri('HEAD', token: token), headers: _api.headers(token)),
      );
      if (res.statusCode != 200) {
        return DiaryGiteeListWithShaResult.error(extractErrorMessage(res));
      }
      final map = json.decode(res.body) as Map<String, dynamic>;
      final tree = map['tree'];
      if (tree is! List) {
        return DiaryGiteeListWithShaResult.error('远端目录结构无效');
      }
      final pathShaMap = <String, String>{};
      for (final item in tree) {
        if (item is! Map) continue;
        final type = item['type']?.toString();
        final path = item['path']?.toString();
        final sha = item['sha']?.toString();
        if (type == 'blob' && path != null && path.isNotEmpty && sha != null && _looksLikeDiaryMd(path)) {
          pathShaMap[path] = sha;
        }
      }
      return DiaryGiteeListWithShaResult.success(pathShaMap);
    } catch (e) {
      return DiaryGiteeListWithShaResult.error('读取远端日记列表失败: $e');
    }
  }
}
