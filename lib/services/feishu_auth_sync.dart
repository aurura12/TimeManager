import 'dart:convert';

import '../config/remote_repo_config.dart';
import '../models/diary_kind.dart';
import '../models/feishu_calendar_models.dart';
import 'diary_local_store.dart';
import 'feishu_calendar_log.dart';
import 'gitee_contents_api.dart';

/// 一次授权同步的读取结果。
class FeishuAuthPullResult {
  const FeishuAuthPullResult({
    this.auth,
    this.notFound = false,
    this.skipped = false,
    this.error,
  });

  const FeishuAuthPullResult.skipped() : this(skipped: true);

  final FeishuRemoteAuth? auth;
  final bool notFound;
  final bool skipped;
  final String? error;

  /// 远端文件读到了（不管里面有没有令牌）。
  bool get available => !skipped && error == null;
}

/// 把飞书凭据和令牌写进同步仓库，让同一身份的其它设备共用一次授权。
///
/// 令牌是刷新一次就换一把的，所以写入必须带 expectedSha 做乐观并发：
/// 另一台同时刷新时，服务端会拒绝后写的一方，由它重新读取对方的令牌。
class FeishuAuthSync {
  static const GiteeContentsApi _api = GiteeContentsApi(
    owner: RemoteRepoConfig.giteeOwner,
    repo: RemoteRepoConfig.giteeRepo,
  );

  static String pathFor(DiaryKind kind) => 'feishu/${kind.code}.json';

  /// 授权同步只是"顺带"，不能把同步主流程卡在慢网络上。
  static const Duration _timeout = Duration(seconds: 8);

  Future<FeishuAuthPullResult> pull(DiaryKind kind) async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.trim().isEmpty) {
      return const FeishuAuthPullResult.skipped();
    }
    final result =
        await _api.pullText(token: token, path: pathFor(kind)).timeout(_timeout,
            onTimeout: () => (
                  success: false,
                  notFound: false,
                  content: null,
                  sha: null,
                  error: '读取授权超时',
                ));
    if (result.success) {
      try {
        final decoded = jsonDecode(result.content ?? '');
        if (decoded is! Map<String, dynamic>) {
          return FeishuAuthPullResult(error: '授权文件格式不正确');
        }
        final auth = FeishuRemoteAuth.fromJson(decoded, sha: result.sha);
        if (auth == null) {
          return FeishuAuthPullResult(error: '授权文件缺少 updated_at');
        }
        return FeishuAuthPullResult(auth: auth);
      } catch (e) {
        return FeishuAuthPullResult(error: '授权文件解析失败: $e');
      }
    }
    if (result.notFound) {
      return const FeishuAuthPullResult(notFound: true);
    }
    return FeishuAuthPullResult(error: result.error ?? '读取授权失败');
  }

  Future<bool> push(
    DiaryKind kind,
    FeishuRemoteAuth auth, {
    String? expectedSha,
    bool expectNotFound = false,
  }) async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.trim().isEmpty) return false;
    final result = await _api
        .pushText(
          token: token,
          path: pathFor(kind),
          content: const JsonEncoder.withIndent('  ').convert(auth.toJson()),
          commitMessage: 'sync(feishu): 更新飞书授权',
          expectedSha: expectedSha,
          expectNotFound: expectNotFound,
        )
        .timeout(_timeout,
            onTimeout: () => (
                  success: false,
                  created: false,
                  sha: null,
                  conflict: false,
                  error: '写入授权超时',
                ));
    if (!result.success) {
      if (result.conflict) {
        feishuLog('飞书授权已被其它设备更新，本次不回写');
      } else {
        feishuLogWarning('写入飞书授权失败：${result.error ?? '未知错误'}');
      }
    }
    return result.success;
  }

  /// 断开授权时写入墓碑，避免另一台设备再把它同步回来。
  Future<void> revoke(DiaryKind kind) async {
    final current = await pull(kind);
    if (!current.available) return;
    await push(
      kind,
      FeishuRemoteAuth(updatedAt: DateTime.now(), revoked: true),
      expectedSha: current.auth?.sha,
      expectNotFound: current.notFound,
    );
  }
}
