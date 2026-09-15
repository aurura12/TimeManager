import '../config/remote_repo_config.dart';
import 'gitee_contents_api.dart';

class DiaryGiteePullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const DiaryGiteePullResult._(
      {required this.success,
      required this.notFound,
      this.content,
      this.sha,
      this.error});

  factory DiaryGiteePullResult.success(String content, String sha) {
    return DiaryGiteePullResult._(
        success: true, notFound: false, content: content, sha: sha);
  }

  factory DiaryGiteePullResult.notFound() {
    return const DiaryGiteePullResult._(success: false, notFound: true);
  }

  factory DiaryGiteePullResult.error(String message) {
    return DiaryGiteePullResult._(
        success: false, notFound: false, error: message);
  }
}

class DiaryGiteePushResult {
  final bool success;
  final bool created;
  final String? sha;
  final bool conflict;
  final String? error;

  const DiaryGiteePushResult._({
    required this.success,
    required this.created,
    this.sha,
    required this.conflict,
    this.error,
  });

  factory DiaryGiteePushResult.success({required bool created, String? sha}) {
    return DiaryGiteePushResult._(
      success: true,
      created: created,
      sha: sha,
      conflict: false,
    );
  }

  factory DiaryGiteePushResult.error(String message) {
    return DiaryGiteePushResult._(
      success: false,
      created: false,
      conflict: false,
      error: message,
    );
  }

  factory DiaryGiteePushResult.conflict(String message) {
    return DiaryGiteePushResult._(
      success: false,
      created: false,
      conflict: true,
      error: message,
    );
  }
}

class DiaryGiteeListResult {
  final bool success;
  final List<String> paths;
  final bool truncated;
  final String? error;

  const DiaryGiteeListResult._(
      {required this.success,
      required this.paths,
      required this.truncated,
      this.error});

  factory DiaryGiteeListResult.success(List<String> paths) {
    return DiaryGiteeListResult._(
        success: true, paths: paths, truncated: false);
  }

  factory DiaryGiteeListResult.error(String message, {bool truncated = false}) {
    return DiaryGiteeListResult._(
        success: false, paths: const [], truncated: truncated, error: message);
  }
}

class DiaryGiteeListWithShaResult {
  final bool success;
  final Map<String, String> pathShaMap;
  final bool truncated;
  final String? error;

  const DiaryGiteeListWithShaResult._(
      {required this.success,
      required this.pathShaMap,
      required this.truncated,
      this.error});

  factory DiaryGiteeListWithShaResult.success(Map<String, String> pathShaMap) {
    return DiaryGiteeListWithShaResult._(
        success: true, pathShaMap: pathShaMap, truncated: false);
  }

  factory DiaryGiteeListWithShaResult.error(
    String message, {
    bool truncated = false,
  }) {
    return DiaryGiteeListWithShaResult._(
        success: false,
        pathShaMap: const {},
        truncated: truncated,
        error: message);
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
    GiteeContentsApi? api,
  }) async {
    final result = await (api ?? _api).pullText(token: token, path: path);
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
    String? expectedSha,
    bool expectNotFound = false,
    GiteeContentsApi? api,
  }) async {
    final result = await (api ?? _api).pushText(
      token: token,
      path: path,
      content: content,
      commitMessage: commitMessage,
      expectedSha: expectedSha,
      expectNotFound: expectNotFound,
    );
    if (result.success) {
      return DiaryGiteePushResult.success(
        created: result.created,
        sha: result.sha,
      );
    }
    if (result.conflict) {
      return DiaryGiteePushResult.conflict(
        result.error ?? '远端日记已更新，请先重新拉取',
      );
    }
    return DiaryGiteePushResult.error(result.error ?? '推送失败');
  }

  static Future<DiaryGiteeListResult> listDiaryPaths({
    required String token,
    GiteeContentsApi? api,
  }) async {
    final result = await listDiaryPathsWithSha(token: token, api: api);
    if (!result.success) {
      return DiaryGiteeListResult.error(
        result.error ?? '读取远端日记列表失败',
        truncated: result.truncated,
      );
    }
    final paths = result.pathShaMap.keys.toList();
    paths.sort((a, b) => b.compareTo(a));
    return DiaryGiteeListResult.success(paths);
  }

  static Future<DiaryGiteeListWithShaResult> listDiaryPathsWithSha({
    required String token,
    GiteeContentsApi? api,
  }) async {
    final treeResult = await (api ?? _api).listTree(
      token: token,
      ref: 'HEAD',
    );
    if (!treeResult.success) {
      return DiaryGiteeListWithShaResult.error(
        treeResult.error ?? '读取远端日记列表失败',
        truncated: treeResult.truncated,
      );
    }

    final pathShaMap = <String, String>{};
    for (final entry in treeResult.entries) {
      if (entry.type == 'blob' && _looksLikeDiaryMd(entry.path)) {
        pathShaMap[entry.path] = entry.sha;
      }
    }
    return DiaryGiteeListWithShaResult.success(pathShaMap);
  }
}
