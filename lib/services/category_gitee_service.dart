import '../config/remote_repo_config.dart';
import 'gitee_contents_api.dart';

class CategoryGiteePullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const CategoryGiteePullResult._({
    required this.success,
    required this.notFound,
    this.content,
    this.sha,
    this.error,
  });

  factory CategoryGiteePullResult.success(String content, String sha) {
    return CategoryGiteePullResult._(
        success: true, notFound: false, content: content, sha: sha);
  }

  factory CategoryGiteePullResult.notFound() {
    return const CategoryGiteePullResult._(success: false, notFound: true);
  }

  factory CategoryGiteePullResult.error(String message) {
    return CategoryGiteePullResult._(
        success: false, notFound: false, error: message);
  }
}

class CategoryGiteePushResult {
  final bool success;
  final bool created;
  final String? error;

  const CategoryGiteePushResult._({
    required this.success,
    required this.created,
    this.error,
  });

  factory CategoryGiteePushResult.success({required bool created}) {
    return CategoryGiteePushResult._(success: true, created: created);
  }

  factory CategoryGiteePushResult.error(String message) {
    return CategoryGiteePushResult._(
        success: false, created: false, error: message);
  }
}

/// Gitee 分类同步服务。
///
/// 每个身份的日程分类存储为 `categories/{userCode}.json`（如 categories/g.json）。
class CategoryGiteeService {
  static const _api = GiteeContentsApi(
    owner: RemoteRepoConfig.giteeOwner,
    repo: RemoteRepoConfig.giteeRepo,
  );

  static String categoryPath(String userCode) => 'categories/$userCode.json';

  /// 拉取指定身份的日程分类文档。
  static Future<CategoryGiteePullResult> pullCategories({
    required String token,
    required String userCode,
  }) async {
    final result = await _api.pullText(
        token: token, path: categoryPath(userCode));
    if (result.success) {
      return CategoryGiteePullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return CategoryGiteePullResult.notFound();
    return CategoryGiteePullResult.error(result.error ?? '拉取失败');
  }

  /// 推送指定身份的日程分类文档。
  static Future<CategoryGiteePushResult> pushCategories({
    required String token,
    required String userCode,
    required String content,
    required String commitMessage,
  }) async {
    final result = await _api.pushText(
      token: token,
      path: categoryPath(userCode),
      content: content,
      commitMessage: commitMessage,
    );
    if (result.success) {
      return CategoryGiteePushResult.success(created: result.created);
    }
    return CategoryGiteePushResult.error(result.error ?? '推送失败');
  }
}
