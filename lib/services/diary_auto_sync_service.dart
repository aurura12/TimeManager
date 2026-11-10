import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/diary_kind.dart';
import '../models/remote_sync_platform.dart';
import '../models/sync_center_state.dart';
import 'app_identity_service.dart';
import 'app_log_service.dart';
import 'diary_local_store.dart';
import 'diary_sync_service.dart';
import 'sync_status_coordinator.dart';

/// 日记自动推送。
///
/// 日记的「拉取」本来就在进页面、切日期、切分区时自动执行（见
/// `DiaryScreen._refreshCurrentContextFromRemote`），这里补上「上传」一侧：
/// 只推送被 [DiaryLocalStore.markDraftPending] 标记过的草稿，复用同步中心
/// 同一批量推送入口（乐观并发 + 正文相同即跳过），所以重复触发不会产生空提交。
///
/// 触发点是「空闲 / 切日 / 切后台 / 离开页面 / 回前台」，都只调用
/// [flush]；远端冲突、离线、未选身份都会保留本机草稿并把结果上报到
/// [SyncStatusCoordinator]，交给页面状态灯和同步中心处理，绝不静默覆盖远端。
class DiaryAutoSyncService {
  DiaryAutoSyncService({
    Future<SyncOperationResult> Function()? syncRunner,
    Future<bool> Function()? pendingChecker,
  })  : _syncRunner = syncRunner ?? _runSync,
        _pendingChecker =
            pendingChecker ?? _hasPendingDraftForCurrentIdentity;

  /// 上报来源，出现在应用日志与同步中心的「最近尝试」里。
  static const String logSource = '日记自动同步';

  /// 跨页面共享的一次执行：空闲推送、切日、回前台可能同时触发，
  /// 这里只保留一次在途任务，后续调用直接复用结果。
  static Future<SyncOperationResult?>? _inFlight;

  final Future<SyncOperationResult> Function() _syncRunner;
  final Future<bool> Function() _pendingChecker;

  /// 只看当前身份的待上传草稿：另一个身份的草稿这次也推不了。
  ///
  /// 未选身份时退回全量扫描，好让 [flush] 仍能上报「尚未选择日记身份」。
  static Future<bool> _hasPendingDraftForCurrentIdentity() async {
    await AppIdentityService.load();
    return DiaryLocalStore.hasPendingDraftFor(AppIdentityService.personKind);
  }

  /// 有待上传草稿时执行一次批量推送；返回 null 表示本次无需同步。
  ///
  /// 没有待上传草稿时连远端列表都不请求，回前台补推因此是零网络开销的。
  Future<SyncOperationResult?> flush({
    SyncStatusCoordinator? coordinator,
  }) async {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    // 先占住在途标记再 await，否则两个触发点会同时通过上面的判空。
    final future = _flushOnce(coordinator);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  Future<SyncOperationResult?> _flushOnce(
    SyncStatusCoordinator? coordinator,
  ) async {
    if (!await _pendingChecker()) return null;
    return _flushInternal(coordinator);
  }

  Future<SyncOperationResult> _flushInternal(
    SyncStatusCoordinator? coordinator,
  ) async {
    await AppIdentityService.load();
    final kind = AppIdentityService.personKind;
    if (kind == null) {
      const result = SyncOperationResult.offline(
        '尚未选择日记身份，草稿保留在本机',
        pendingUploadCount: 1,
      );
      coordinator?.report(SyncModule.diary, result, source: logSource);
      return result;
    }

    final scope = '${kind.code}:${RemoteSyncPlatform.gitee.name}';
    coordinator?.begin(
      SyncModule.diary,
      message: '正在自动上传日记',
      source: logSource,
      scope: scope,
    );

    SyncOperationResult result;
    try {
      result = await _syncRunner();
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '日记自动上传异常',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      result = SyncOperationResult.failed(
        '日记自动上传失败：$error',
        pendingUploadCount: 1,
      );
    }

    coordinator?.report(SyncModule.diary, result,
        source: logSource, scope: scope);
    return result;
  }

  // 自动推送只负责把草稿推上去；没有草稿时不该顺带刷新整份日记索引，
  // 否则回前台的补推会变成一次全量索引重建（带进度条）。
  static Future<SyncOperationResult> _runSync() =>
      DiarySyncService().sync(refreshWhenNoDrafts: false);

  @visibleForTesting
  static void resetForTesting() {
    _inFlight = null;
  }
}
