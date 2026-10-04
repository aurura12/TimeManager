import '../config/remote_repo_config.dart';
import 'diary_local_store.dart';
import 'gitee_contents_api.dart';

typedef WakeUpPullResult = ({
  bool success,
  bool notFound,
  String? content,
  String? sha,
  String? error,
});
typedef WakeUpPushResult = ({bool success, bool conflict, String? error});

/// 起床记录使用独立文档，避免旧版本上传目标时丢掉新增字段。
class WakeUpGiteeService {
  WakeUpGiteeService({GiteeContentsApi? api})
      : _api = api ??
            const GiteeContentsApi(
              owner: RemoteRepoConfig.giteeOwner,
              repo: RemoteRepoConfig.giteeRepo,
            );

  final GiteeContentsApi _api;
  static String pathFor(String userCode) => 'wake_up/$userCode.json';

  Future<WakeUpPullResult> pull(
          {required String token, required String userCode}) =>
      _api.pullText(token: token, path: pathFor(userCode));

  Future<WakeUpPushResult> push({
    required String token,
    required String userCode,
    required String content,
    required String commitMessage,
    String? expectedSha,
    bool expectNotFound = false,
  }) async {
    final result = await _api.pushText(
      token: token,
      path: pathFor(userCode),
      content: content,
      commitMessage: commitMessage,
      expectedSha: expectedSha,
      expectNotFound: expectNotFound,
    );
    return (
      success: result.success,
      conflict: result.conflict ||
          (expectNotFound && result.error == '远端文件已发生变化，请先重新拉取'),
      error: result.error,
    );
  }
}

class WakeUpSyncDependencies {
  const WakeUpSyncDependencies({
    required this.loadToken,
    required this.pull,
    required this.push,
    this.enabled = true,
  });

  final bool enabled;
  final Future<String?> Function() loadToken;
  final Future<WakeUpPullResult> Function(
      {required String token, required String userCode}) pull;
  final Future<WakeUpPushResult> Function({
    required String token,
    required String userCode,
    required String content,
    required String commitMessage,
    String? expectedSha,
    bool expectNotFound,
  }) push;

  factory WakeUpSyncDependencies.production() {
    final service = WakeUpGiteeService();
    return WakeUpSyncDependencies(
        loadToken: DiaryLocalStore.loadToken,
        pull: service.pull,
        push: service.push);
  }

  /// 页面级离线测试默认不连接远端，应用入口明确注入 production。
  factory WakeUpSyncDependencies.disabled() => WakeUpSyncDependencies(
        enabled: false,
        loadToken: () async => null,
        pull: ({required token, required userCode}) async => (
          success: false,
          notFound: true,
          content: null,
          sha: null,
          error: null
        ),
        push: (
                {required token,
                required userCode,
                required content,
                required commitMessage,
                String? expectedSha,
                bool expectNotFound = false}) async =>
            (success: false, conflict: false, error: '起床同步未启用'),
      );
}
