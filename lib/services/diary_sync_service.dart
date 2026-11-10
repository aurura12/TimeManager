import 'dart:async';

import 'package:intl/intl.dart';

import '../models/diary_kind.dart';
import '../utils/diary_markdown.dart';
import '../models/sync_center_state.dart';
import 'app_identity_service.dart';
import 'diary_gitee_service.dart';
import 'diary_local_store.dart';
import 'diary_search_service.dart';
import 'sync_operation_lock.dart';

typedef DiaryListLoader = Future<DiaryGiteeListWithShaResult> Function(
  String token,
);

typedef DiaryPullLoader = Future<DiaryGiteePullResult> Function({
  required String token,
  required String path,
});

typedef DiaryPushLoader = Future<DiaryGiteePushResult> Function({
  required String token,
  required String path,
  required String content,
  required String commitMessage,
  String? expectedSha,
  bool expectNotFound,
});

typedef DiaryCacheUpdater = Future<void> Function(
  String kind,
  DateTime date,
  String content,
);

typedef DiaryCacheRefresher = Future<void> Function(String token);

/// 同步中心使用的日记批量同步入口。
///
/// 日记编辑器保存的是本地草稿，单纯刷新远端索引并不等于草稿已经上传。
/// 这里复用编辑器的乐观并发规则：有基线才允许覆盖已有远端文件；基线
/// 缺失时只有确认正文已经相同，或远端文件确实不存在，才会继续。
class DiarySyncService {
  DiarySyncService({
    Future<String?> Function()? tokenLoader,
    DiaryListLoader? listLoader,
    DiaryPullLoader? pullLoader,
    DiaryPushLoader? pushLoader,
    DiaryCacheUpdater? cacheUpdater,
    DiaryCacheRefresher? cacheRefresher,
  })  : _tokenLoader = tokenLoader ?? DiaryLocalStore.loadToken,
        _listLoader = listLoader ??
            ((token) => DiaryGiteeService.listDiaryPathsWithSha(token: token)),
        _pullLoader = pullLoader ??
            (({required token, required path}) =>
                DiaryGiteeService.pullDiary(token: token, path: path)),
        _pushLoader = pushLoader ??
            (({
              required token,
              required path,
              required content,
              required commitMessage,
              expectedSha,
              expectNotFound = false,
            }) =>
                DiaryGiteeService.pushDiary(
                  token: token,
                  path: path,
                  content: content,
                  commitMessage: commitMessage,
                  expectedSha: expectedSha,
                  expectNotFound: expectNotFound,
                )),
        _cacheUpdater = cacheUpdater ?? DiarySearchService.updateCache,
        _cacheRefresher = cacheRefresher ?? DiarySearchService.refreshCache;

  final Future<String?> Function() _tokenLoader;
  final DiaryListLoader _listLoader;
  final DiaryPullLoader _pullLoader;
  final DiaryPushLoader _pushLoader;
  final DiaryCacheUpdater _cacheUpdater;
  final DiaryCacheRefresher _cacheRefresher;

  /// [refreshWhenNoDrafts] 为 false 时，没有可上传草稿就直接返回，不刷新
  /// 远端索引：自动推送只由草稿变化触发，不该在回前台时重建整份索引。
  Future<SyncOperationResult> sync({bool refreshWhenNoDrafts = true}) {
    return SyncOperationLock.instance.run(
      SyncModule.diary,
      () => _syncInternal(refreshWhenNoDrafts: refreshWhenNoDrafts),
    );
  }

  /// 冲突处理的另一半：**用本地内容覆盖远端**。
  ///
  /// 只在用户明确确认后调用。与 [sync] 的区别是不比对编辑基线，而是重新读取
  /// 远端当前版本后以它为 expectedSha 强推；推之前远端若又被改过会判冲突，
  /// 不会无声覆盖。调用方负责把「会覆盖别人刚写的内容」讲清楚。
  ///
  /// [expectRemoteAbsent] 表示「用户确认时远端这篇还不存在」（合并对比的是
  /// 空远端）；期间如果远端重新出现，宁可判冲突也不能把它覆盖掉。
  Future<SyncOperationResult> overwriteRemote({
    required DiaryKind kind,
    required DateTime date,
    String? path,
    String? body,
    String? expectedRemoteSha,
    bool expectRemoteAbsent = false,
  }) {
    return SyncOperationLock.instance.run(
      SyncModule.diary,
      () => _overwriteRemoteInternal(
        kind,
        date,
        path: path,
        bodyOverride: body,
        expectedRemoteSha: expectedRemoteSha,
        expectRemoteAbsent: expectRemoteAbsent,
      ),
    );
  }

  Future<SyncOperationResult> _overwriteRemoteInternal(
    DiaryKind kind,
    DateTime date, {
    String? path,
    String? bodyOverride,
    String? expectedRemoteSha,
    bool expectRemoteAbsent = false,
  }) async {
    await AppIdentityService.load();
    final identity = AppIdentityService.personKind;
    if (identity == null) {
      return const SyncOperationResult.offline('尚未选择日记身份，本地草稿会保留');
    }
    if (identity != kind) {
      return const SyncOperationResult.skipped('当前分区只读，不能覆盖远端');
    }

    final token = (await _tokenLoader())?.trim();
    if (token == null || token.isEmpty) {
      return const SyncOperationResult.offline(
        '日记远端未连接，本地草稿会保留',
        pendingUploadCount: 1,
      );
    }

    final content =
        bodyOverride ?? (await DiaryLocalStore.loadDraftBody(kind, date)) ?? '';
    if (content.trim().isEmpty) {
      return const SyncOperationResult.skipped('这篇日记还没有内容');
    }
    final startedAt =
        await DiaryLocalStore.loadDraftStartedAt(kind, date) ?? date;
    final dateText = DateFormat('yyyy年M月d日').format(date);

    String targetPath;
    if (path != null && path.trim().isNotEmpty) {
      // 页面已经解析好（含「多文件命中」时用户 pin 的路径），优先使用。
      targetPath = path.trim();
    } else {
      final listing = await _listLoader(token);
      if (!listing.success) {
        return SyncOperationResult.failed(
          '日记同步失败：${listing.error ?? '远端列表不可用'}',
          pendingUploadCount: 1,
        );
      }
      final matches = listing.pathShaMap.keys
          .where((item) => _matchesKindAndDate(item, kind, dateText))
          .toList(growable: false);
      if (matches.length > 1) {
        return const SyncOperationResult.failed(
          '该日期命中多个远端文件，请从远程文件树点开目标文件后再处理',
          pendingUploadCount: 1,
        );
      }
      targetPath =
          matches.isEmpty ? '${kind.prefix}$dateText.md' : matches.single;
    }

    final remote = await _pullLoader(token: token, path: targetPath);
    String? expectedSha;
    var expectNotFound = false;
    if (remote.notFound) {
      if (expectedRemoteSha != null && !expectRemoteAbsent) {
        return const SyncOperationResult.conflict(
          '远端这篇已被删除，请重新处理',
          pendingUploadCount: 1,
        );
      }
      expectNotFound = true;
    } else if (!remote.success || remote.content == null) {
      return SyncOperationResult.failed(
        '日记同步失败：${remote.error ?? '读取远端内容失败'}',
        pendingUploadCount: 1,
      );
    } else {
      if (_normalizedBody(remote.content!) == _normalizedBody(content)) {
        // 远端已经与本地一致：只需补基线与清待上传标记，不再造一个空提交。
        if (remote.sha != null) {
          await DiaryLocalStore.saveRemoteBaseline(
            kind,
            date,
            path: targetPath,
            sha: remote.sha,
            notFound: false,
          );
        }
        await _cacheUpdater(kind.code, date, remote.content!);
        await DiaryLocalStore.clearDraftPending(kind, date);
        return const SyncOperationResult.success(message: '本地与远端已一致');
      }
      if (expectRemoteAbsent) {
        // 用户确认合并时远端这篇还不存在，现在又出现了：多半是对方刚写好，
        // 直接推会把他们的内容覆盖掉。
        return const SyncOperationResult.conflict(
          '远端这篇在确认期间重新出现，请重新处理冲突',
          pendingUploadCount: 1,
        );
      }
      if (expectedRemoteSha != null && remote.sha != expectedRemoteSha) {
        // 用户查看冲突期间远端又变了：拒绝覆盖，让用户重新确认。
        return const SyncOperationResult.conflict(
          '远端已再次更新，请重新处理冲突',
          pendingUploadCount: 1,
        );
      }
      if (remote.sha == null) {
        return const SyncOperationResult.failed(
          '未能获取远端版本，请稍后重试',
          pendingUploadCount: 1,
        );
      }
      expectedSha = remote.sha;
    }

    final draft = DiaryLocalDraft(
      kind: kind,
      date: date,
      body: content,
      startedAt: startedAt,
    );
    final markdown = _buildMarkdown(draft);
    final userLabel = kind == DiaryKind.g ? '乖乖' : '晶晶';
    final push = await _pushLoader(
      token: token,
      path: targetPath,
      content: markdown,
      commitMessage: 'diary($userLabel): overwrite $targetPath',
      expectedSha: expectedSha,
      expectNotFound: expectNotFound,
    );
    if (!push.success) {
      return push.conflict
          ? const SyncOperationResult.conflict(
              '远端刚刚又被更新，请确认后再试一次',
              pendingUploadCount: 1,
            )
          : SyncOperationResult.failed(
              '日记同步失败：${push.error ?? '推送失败'}',
              pendingUploadCount: 1,
            );
    }

    if (push.sha != null) {
      await DiaryLocalStore.saveRemoteBaseline(
        kind,
        date,
        path: targetPath,
        sha: push.sha!,
        notFound: false,
      );
    } else {
      await DiaryLocalStore.removeRemoteBaseline(kind, date);
    }
    await _cacheUpdater(kind.code, date, markdown);
    await DiaryLocalStore.clearDraftPending(kind, date);
    return const SyncOperationResult.success(message: '已用本地内容覆盖远端');
  }

  Future<SyncOperationResult> _syncInternal({
    bool refreshWhenNoDrafts = true,
  }) async {
    await AppIdentityService.load();
    final kind = AppIdentityService.personKind;
    if (kind == null) {
      return const SyncOperationResult.offline('请先选择日记身份，本地草稿会保留');
    }

    final token = (await _tokenLoader())?.trim();
    if (token == null || token.isEmpty) {
      return const SyncOperationResult.offline(
        '日记远端未连接，本地草稿会保留',
      );
    }

    final drafts = await DiaryLocalStore.loadDrafts(kind: kind);
    if (drafts.isEmpty) {
      // 没有明确待上传草稿时只刷新远端索引，不主动创建历史本地草稿对应的
      // 文件。这样“全部重试”不会把用户从未主动推送过的旧草稿批量发布。
      if (!refreshWhenNoDrafts) {
        return const SyncOperationResult.success(message: '没有待上传的日记');
      }
      await _cacheRefresher(token);
      return const SyncOperationResult.success(message: '日记索引已刷新，没有待上传草稿');
    }

    final listing = await _listLoader(token);
    if (!listing.success) {
      return SyncOperationResult.failed(
        '日记同步失败：${listing.error ?? '远端列表不可用'}',
        pendingUploadCount: drafts.length,
      );
    }

    final conflicts = <String>[];
    var failedCount = 0;
    var syncedCount = 0;
    var listingForSha = listing.pathShaMap;

    for (final draft in drafts) {
      final dateText = DateFormat('yyyy年M月d日').format(draft.date);
      final defaultPath = '${draft.kind.prefix}$dateText.md';
      final matches = listingForSha.keys
          .where((path) => _matchesKindAndDate(path, draft.kind, dateText))
          .toList(growable: false);
      if (matches.length > 1) {
        conflicts.add('$defaultPath（命中多个远端文件）');
        continue;
      }

      final path = matches.isEmpty ? defaultPath : matches.single;
      final markdown = _buildMarkdown(draft);
      final baseline = await DiaryLocalStore.loadRemoteBaseline(
        draft.kind,
        draft.date,
      );

      String? expectedSha;
      var expectNotFound = false;
      if (matches.isEmpty) {
        if (baseline != null && !baseline.notFound) {
          conflicts.add('$path（远端路径发生变化）');
          continue;
        }
        expectNotFound = true;
      } else {
        final remote = await _pullLoader(token: token, path: path);
        if (!remote.success || remote.content == null || remote.sha == null) {
          failedCount++;
          continue;
        }
        final remoteSha = remote.sha!;

        // 先按正文判断幂等：即使远端 front matter 或 sha 已变化，只要
        // 用户草稿与远端正文一致，就无需再创建一次提交。
        if (_normalizedBody(remote.content!) == _normalizedBody(draft.body)) {
          await _saveBaseline(draft, path: path, sha: remoteSha);
          await _cacheUpdater(draft.kind.code, draft.date, remote.content!);
          await DiaryLocalStore.clearDraftPending(draft.kind, draft.date);
          syncedCount++;
          continue;
        }

        if (baseline == null ||
            baseline.notFound ||
            baseline.path != path ||
            baseline.sha == null ||
            baseline.sha != remoteSha) {
          conflicts.add('$path（远端已更新，请先从日记页拉取）');
          continue;
        }
        expectedSha = baseline.sha;
      }

      final push = await _pushLoader(
        token: token,
        path: path,
        content: markdown,
        commitMessage:
            'diary(${draft.kind == DiaryKind.g ? '乖乖' : '晶晶'}): update $path',
        expectedSha: expectedSha,
        expectNotFound: expectNotFound,
      );
      if (!push.success) {
        if (push.conflict) {
          conflicts.add('$path（远端已更新，请先从日记页拉取）');
        } else {
          failedCount++;
        }
        continue;
      }

      var pushedSha = push.sha;
      if (pushedSha == null) {
        // 兼容旧宿主没有返回 push sha 的情况；重新列目录只为保存可靠
        // 基线，避免下一次重试在未知版本上覆盖远端。
        final refreshed = await _listLoader(token);
        if (refreshed.success) {
          listingForSha = refreshed.pathShaMap;
          pushedSha = listingForSha[path];
        }
      }
      if (pushedSha == null) {
        await DiaryLocalStore.removeRemoteBaseline(draft.kind, draft.date);
      } else {
        await _saveBaseline(draft, path: path, sha: pushedSha);
      }
      await _cacheUpdater(draft.kind.code, draft.date, markdown);
      await DiaryLocalStore.clearDraftPending(draft.kind, draft.date);
      syncedCount++;
    }

    final remaining = conflicts.length + failedCount;
    if (conflicts.isNotEmpty) {
      return SyncOperationResult.conflict(
        '日记同步完成 $syncedCount 篇，但仍有 ${conflicts.length} 篇需要确认',
        conflictCount: conflicts.length,
        pendingUploadCount: remaining,
        details: conflicts.take(10).toList(growable: false),
      );
    }
    if (failedCount > 0) {
      return SyncOperationResult.failed(
        '日记已同步 $syncedCount 篇，仍有 $failedCount 篇待重试',
        pendingUploadCount: remaining,
      );
    }
    return SyncOperationResult.success(
      message: '日记已同步 $syncedCount 篇',
    );
  }

  Future<void> _saveBaseline(
    DiaryLocalDraft draft, {
    required String path,
    required String sha,
  }) {
    return DiaryLocalStore.saveRemoteBaseline(
      draft.kind,
      draft.date,
      path: path,
      sha: sha,
      notFound: false,
    );
  }

  static bool _matchesKindAndDate(
    String path,
    DiaryKind kind,
    String dateText,
  ) {
    final fileName = path.split('/').last;
    return fileName.endsWith('.md') &&
        fileName.startsWith(kind == DiaryKind.g ? 'G' : 'J') &&
        fileName.contains(dateText);
  }

  static String _buildMarkdown(DiaryLocalDraft draft) {
    final started = draft.startedAt ?? draft.date;
    final dayText = DateFormat('yyyy年M月d日').format(started);
    final date = DateFormat('yyyy-MM-dd HH:mm:ss').format(started);
    return '---\n'
        'title: ${draft.kind.prefix}$dayText\n'
        'date: $date\n'
        'tags:\n'
        '---\n'
        '\n'
        '${draft.body}';
  }

  static String _normalizedBody(String value) => normalizeDiaryBody(value);
}
