import '../config/remote_repo_config.dart';
import 'gitee_contents_api.dart';

class ScheduleGiteePullResult {
  final bool success;
  final bool notFound;
  final String? content;
  final String? sha;
  final String? error;

  const ScheduleGiteePullResult._({required this.success, required this.notFound, this.content, this.sha, this.error});

  factory ScheduleGiteePullResult.success(String content, String sha) {
    return ScheduleGiteePullResult._(success: true, notFound: false, content: content, sha: sha);
  }

  factory ScheduleGiteePullResult.notFound() {
    return const ScheduleGiteePullResult._(success: false, notFound: true);
  }

  factory ScheduleGiteePullResult.error(String message) {
    return ScheduleGiteePullResult._(success: false, notFound: false, error: message);
  }
}

class ScheduleGiteePushResult {
  final bool success;
  final bool created;

  /// 写入后远端产生的新 blob SHA，用于回写同步基线。
  /// 服务端没回传（旧实现/空响应）时为 null。
  final String? sha;
  final String? error;

  const ScheduleGiteePushResult._({
    required this.success,
    required this.created,
    this.sha,
    this.error,
  });

  factory ScheduleGiteePushResult.success({required bool created, String? sha}) {
    return ScheduleGiteePushResult._(success: true, created: created, sha: sha);
  }

  factory ScheduleGiteePushResult.error(String message) {
    return ScheduleGiteePushResult._(success: false, created: false, error: message);
  }
}

class ScheduleGiteeListWithShaResult {
  final bool success;
  final Map<String, String> pathShaMap; // path → sha
  final String? error;

  const ScheduleGiteeListWithShaResult._({
    required this.success,
    required this.pathShaMap,
    this.error,
  });

  factory ScheduleGiteeListWithShaResult.success(Map<String, String> map) {
    return ScheduleGiteeListWithShaResult._(success: true, pathShaMap: map);
  }

  factory ScheduleGiteeListWithShaResult.error(String message) {
    return ScheduleGiteeListWithShaResult._(
        success: false, pathShaMap: const {}, error: message);
  }
}

/// Gitee 日程同步服务。
///
/// 每天日程存储为 `schedule/{YYYY-M-D}.json`，内容为 TimeSlot 稀疏数组。
class ScheduleGiteeService {
  static const _api = GiteeContentsApi(
    owner: RemoteRepoConfig.giteeOwner,
    repo: RemoteRepoConfig.giteeRepo,
  );

  static String schedulePath(String dateKey, {required String userCode}) =>
      'schedule/$userCode/$dateKey.json';

  /// 拉取指定日期的日程文件。
  static Future<ScheduleGiteePullResult> pullSchedule({
    required String token,
    required String dateKey,
    required String userCode,
  }) async {
    final result = await _api.pullText(token: token, path: schedulePath(dateKey, userCode: userCode));
    if (result.success) {
      return ScheduleGiteePullResult.success(result.content!, result.sha!);
    }
    if (result.notFound) return ScheduleGiteePullResult.notFound();
    return ScheduleGiteePullResult.error(result.error ?? '拉取失败');
  }

  /// 推送指定日期的日程文件。
  ///
  /// [expectedSha] / [expectNotFound] 由调用方在"先拉取再合并"的那次读取中获得，
  /// 用于乐观并发控制：读取之后若远端被别的设备改过，服务端会拒绝写入，
  /// 避免用本地内容覆盖掉对方的更新。
  static Future<ScheduleGiteePushResult> pushSchedule({
    required String token,
    required String dateKey,
    required String userCode,
    required String content,
    required String commitMessage,
    String? expectedSha,
    bool expectNotFound = false,
  }) async {
    final result = await _api.pushText(
      token: token,
      path: schedulePath(dateKey, userCode: userCode),
      content: content,
      commitMessage: commitMessage,
      expectedSha: expectedSha,
      expectNotFound: expectNotFound,
    );
    if (result.success) {
      return ScheduleGiteePushResult.success(
        created: result.created,
        sha: result.sha,
      );
    }
    return ScheduleGiteePushResult.error(result.error ?? '推送失败');
  }

  /// 列出指定用户的所有日程文件路径（schedule/{userCode}/{dateKey}.json），返回 path→sha。
  ///
  /// 必须复用 [GiteeContentsApi.listTree]：它会处理 Gitee 返回的 `truncated`
  /// 并按子树 SHA 展开。裸调 tree 接口拿到被截断的列表时，缺失的日程文件会被
  /// 误判成"远端不存在"，之后长期看不到远端的修改。
  static Future<ScheduleGiteeListWithShaResult> listSchedulePathsWithSha({
    required String token,
    required String userCode,
  }) async {
    final result = await _api.listTree(token: token);
    if (!result.success) {
      return ScheduleGiteeListWithShaResult.error(
        result.error ?? '读取远端日程列表失败',
      );
    }
    final prefix = 'schedule/$userCode/';
    final pathShaMap = <String, String>{};
    for (final entry in result.entries) {
      if (entry.type != 'blob') continue;
      if (!entry.path.startsWith(prefix) || !entry.path.endsWith('.json')) {
        continue;
      }
      if (entry.sha.trim().isEmpty) continue;
      pathShaMap[entry.path] = entry.sha;
    }
    return ScheduleGiteeListWithShaResult.success(pathShaMap);
  }
}
