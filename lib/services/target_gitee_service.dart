import '../config/remote_repo_config.dart';
import 'gitee_contents_api.dart';

class TargetGiteePullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const TargetGiteePullResult._({
    required this.success,
    required this.notFound,
    this.content,
    this.sha,
    this.error,
  });

  factory TargetGiteePullResult.success(String content, String sha) {
    return TargetGiteePullResult._(
      success: true,
      notFound: false,
      content: content,
      sha: sha,
    );
  }

  factory TargetGiteePullResult.notFound() {
    return const TargetGiteePullResult._(success: false, notFound: true);
  }

  factory TargetGiteePullResult.error(String message) {
    return TargetGiteePullResult._(
      success: false,
      notFound: false,
      error: message,
    );
  }
}

class TargetGiteePushResult {
  final bool success;
  final bool created;
  final String? error;

  const TargetGiteePushResult._({
    required this.success,
    required this.created,
    this.error,
  });

  factory TargetGiteePushResult.success({required bool created}) {
    return TargetGiteePushResult._(success: true, created: created);
  }

  factory TargetGiteePushResult.error(String message) {
    return TargetGiteePushResult._(
      success: false,
      created: false,
      error: message,
    );
  }
}

/// Gitee 目标同步服务。
///
/// 每个身份的目标存储为 `targets/{userCode}.json`。
class TargetGiteeService {
  static const _api = GiteeContentsApi(
    owner: RemoteRepoConfig.giteeOwner,
    repo: RemoteRepoConfig.giteeRepo,
  );

  static String targetPath(String userCode) => 'targets/$userCode.json';

  static Future<TargetGiteePullResult> pullTargets({
    required String token,
    required String userCode,
  }) async {
    final result = await _api.pullText(
      token: token,
      path: targetPath(userCode),
    );
    if (result.success) {
      return TargetGiteePullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return TargetGiteePullResult.notFound();
    return TargetGiteePullResult.error(result.error ?? '拉取失败');
  }

  static Future<TargetGiteePushResult> pushTargets({
    required String token,
    required String userCode,
    required String content,
    required String commitMessage,
  }) async {
    final result = await _api.pushText(
      token: token,
      path: targetPath(userCode),
      content: content,
      commitMessage: commitMessage,
    );
    if (result.success) {
      return TargetGiteePushResult.success(created: result.created);
    }
    return TargetGiteePushResult.error(result.error ?? '推送失败');
  }
}
