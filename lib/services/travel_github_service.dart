import '../config/remote_repo_config.dart';
import 'github_contents_api.dart';

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

/// GitHub 出行同步服务。
class TravelGitHubService {
  static const _api = GitHubContentsApi(
    owner: RemoteRepoConfig.githubOwner,
    repo: RemoteRepoConfig.githubRepo,
  );

  static Future<TravelPullResult> pullFile({
    required String token,
    required String path,
  }) async {
    final result = await _api.pullText(token: token, path: path);
    if (result.success) {
      return TravelPullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return TravelPullResult.notFound();
    return TravelPullResult.error(result.error ?? '拉取失败');
  }

  static Future<TravelPushResult> pushFile({
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
      return TravelPushResult.success(created: result.created);
    }
    return TravelPushResult.error(result.error ?? '推送失败');
  }
}
