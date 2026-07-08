import '../config/remote_repo_config.dart';
import 'gitee_contents_api.dart';

class TravelGiteePullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const TravelGiteePullResult._({required this.success, required this.notFound, this.content, this.sha, this.error});

  factory TravelGiteePullResult.success(String content, String sha) {
    return TravelGiteePullResult._(success: true, notFound: false, content: content, sha: sha);
  }

  factory TravelGiteePullResult.notFound() {
    return const TravelGiteePullResult._(success: false, notFound: true);
  }

  factory TravelGiteePullResult.error(String message) {
    return TravelGiteePullResult._(success: false, notFound: false, error: message);
  }
}

class TravelGiteePushResult {
  final bool success;
  final bool created;
  final String? error;

  const TravelGiteePushResult._({required this.success, required this.created, this.error});

  factory TravelGiteePushResult.success({required bool created}) {
    return TravelGiteePushResult._(success: true, created: created);
  }

  factory TravelGiteePushResult.error(String message) {
    return TravelGiteePushResult._(success: false, created: false, error: message);
  }
}

/// Gitee 出行同步服务。
class TravelGiteeService {
  static const _api = GiteeContentsApi(
    owner: RemoteRepoConfig.giteeOwner,
    repo: RemoteRepoConfig.giteeRepo,
  );

  static Future<TravelGiteePullResult> pullFile({
    required String token,
    required String path,
  }) async {
    final result = await _api.pullText(token: token, path: path);
    if (result.success) {
      return TravelGiteePullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return TravelGiteePullResult.notFound();
    return TravelGiteePullResult.error(result.error ?? '拉取失败');
  }

  static Future<TravelGiteePushResult> pushFile({
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
      return TravelGiteePushResult.success(created: result.created);
    }
    return TravelGiteePushResult.error(result.error ?? '推送失败');
  }
}
