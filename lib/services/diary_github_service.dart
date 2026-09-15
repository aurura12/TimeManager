import '../config/remote_repo_config.dart';
import 'github_contents_api.dart';

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
  final bool truncated;
  final String? error;

  const DiaryListResult._({
    required this.success,
    required this.paths,
    required this.truncated,
    this.error,
  });

  factory DiaryListResult.success(List<String> paths) {
    return DiaryListResult._(
      success: true,
      paths: paths,
      truncated: false,
    );
  }

  factory DiaryListResult.error(String message, {bool truncated = false}) {
    return DiaryListResult._(
      success: false,
      paths: const [],
      truncated: truncated,
      error: message,
    );
  }
}

class DiaryListWithShaResult {
  final bool success;
  final Map<String, String> pathShaMap;
  final bool truncated;
  final String? error;

  const DiaryListWithShaResult._({
    required this.success,
    required this.pathShaMap,
    required this.truncated,
    this.error,
  });

  factory DiaryListWithShaResult.success(Map<String, String> pathShaMap) {
    return DiaryListWithShaResult._(
      success: true,
      pathShaMap: pathShaMap,
      truncated: false,
    );
  }

  factory DiaryListWithShaResult.error(
    String message, {
    bool truncated = false,
  }) {
    return DiaryListWithShaResult._(
      success: false,
      pathShaMap: const {},
      truncated: truncated,
      error: message,
    );
  }
}

/// GitHub 日记同步服务。
class DiaryGitHubService {
  static const _api = GitHubContentsApi(
    owner: RemoteRepoConfig.githubOwner,
    repo: RemoteRepoConfig.githubRepo,
  );

  static bool _looksLikeDiaryMd(String path) {
    final lower = path.toLowerCase();
    if (!lower.endsWith('.md')) return false;
    final fileName = path.split('/').last;
    return fileName.startsWith('G') || fileName.startsWith('J');
  }

  static Future<DiaryPullResult> pullDiary({
    required String token,
    required String path,
    GitHubContentsApi? api,
  }) async {
    final result = await (api ?? _api).pullText(token: token, path: path);
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
    GitHubContentsApi? api,
  }) async {
    final result = await (api ?? _api).pushText(
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
    GitHubContentsApi? api,
  }) async {
    final result = await listDiaryPathsWithSha(token: token, api: api);
    if (!result.success) {
      return DiaryListResult.error(
        result.error ?? '读取远端日记列表失败',
        truncated: result.truncated,
      );
    }
    final paths = result.pathShaMap.keys.toList();
    paths.sort((a, b) => b.compareTo(a));
    return DiaryListResult.success(paths);
  }

  static Future<DiaryListWithShaResult> listDiaryPathsWithSha({
    required String token,
    GitHubContentsApi? api,
  }) async {
    final treeResult = await (api ?? _api).listTree(
      token: token,
      ref: 'HEAD',
    );
    if (!treeResult.success) {
      return DiaryListWithShaResult.error(
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
    return DiaryListWithShaResult.success(pathShaMap);
  }
}
