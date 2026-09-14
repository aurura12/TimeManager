import 'diary_local_store.dart';
import 'target_gitee_service.dart';

typedef TargetTokenLoader = Future<String?> Function();
typedef TargetDocumentLoader = Future<TargetGiteePullResult> Function({
  required String token,
  required String userCode,
});
typedef TargetDocumentPusher = Future<TargetGiteePushResult> Function({
  required String token,
  required String userCode,
  required String content,
  required String commitMessage,
  /// 读取远端时拿到的 sha；写入时交给服务端做版本校验。
  String? expectedSha,
  /// 读取时远端文件不存在（此时 expectedSha 为 null）。
  bool expectNotFound,
});

class TargetSyncDependencies {
  const TargetSyncDependencies({
    required this.loadToken,
    required this.pullTargets,
    required this.pushTargets,
  });

  final TargetTokenLoader loadToken;
  final TargetDocumentLoader pullTargets;
  final TargetDocumentPusher pushTargets;

  factory TargetSyncDependencies.production() {
    return TargetSyncDependencies(
      loadToken: DiaryLocalStore.loadToken,
      pullTargets: TargetGiteeService.pullTargets,
      pushTargets: TargetGiteeService.pushTargets,
    );
  }

  /// 用于离线测试或只测试日程同步的 Provider，避免意外发起网络请求。
  factory TargetSyncDependencies.disabled() {
    return TargetSyncDependencies(
      loadToken: () async => null,
      pullTargets: ({required token, required userCode}) async {
        return TargetGiteePullResult.notFound();
      },
      pushTargets: ({
        required token,
        required userCode,
        required content,
        required commitMessage,
        String? expectedSha,
        bool expectNotFound = false,
      }) async {
        return TargetGiteePushResult.success(created: false);
      },
    );
  }
}
