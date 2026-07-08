import 'dart:convert';

import '../config/remote_repo_config.dart';
import 'contents_api_common.dart';
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
  final String? error;

  const ScheduleGiteePushResult._({required this.success, required this.created, this.error});

  factory ScheduleGiteePushResult.success({required bool created}) {
    return ScheduleGiteePushResult._(success: true, created: created);
  }

  factory ScheduleGiteePushResult.error(String message) {
    return ScheduleGiteePushResult._(success: false, created: false, error: message);
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
  static Future<ScheduleGiteePushResult> pushSchedule({
    required String token,
    required String dateKey,
    required String userCode,
    required String content,
    required String commitMessage,
  }) async {
    final result = await _api.pushText(
      token: token,
      path: schedulePath(dateKey, userCode: userCode),
      content: content,
      commitMessage: commitMessage,
    );
    if (result.success) {
      return ScheduleGiteePushResult.success(created: result.created);
    }
    return ScheduleGiteePushResult.error(result.error ?? '推送失败');
  }
}
