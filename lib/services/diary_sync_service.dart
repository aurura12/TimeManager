import 'dart:async';

import 'package:intl/intl.dart';

import '../models/diary_kind.dart';
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

  Future<SyncOperationResult> sync() {
    return SyncOperationLock.instance.run(SyncModule.diary, _syncInternal);
  }

  Future<SyncOperationResult> _syncInternal() async {
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

  static String _normalizedBody(String value) {
    final match = RegExp(r'^---\n([\s\S]*?)\n---\n?', multiLine: false)
        .firstMatch(value.replaceAll('\r\n', '\n'));
    final body = match == null
        ? value
        : value.replaceAll('\r\n', '\n').substring(match.end);
    return body.trim();
  }
}
