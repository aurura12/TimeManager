import 'dart:async';
import 'dart:io';

import '../models/check_in_document.dart';
import '../models/check_in_goal.dart';
import '../models/check_in_record.dart';
import '../models/diary_kind.dart';
import '../models/google_calendar_user.dart';
import '../models/known_google_users.dart';
import 'app_user_identity_store.dart';
import 'check_in_gitee_service.dart';
import 'check_in_image_service.dart';
import 'check_in_local_store.dart';
import 'check_in_location_service.dart';
import 'check_in_photo_cache.dart';
import 'diary_local_store.dart';
import 'google_calendar_service.dart';
import 'app_identity_service.dart';
import '../utils/platform_features.dart';

class CheckInSyncResult {
  final bool success;
  final String? error;
  final CheckInDocument? document;

  const CheckInSyncResult._({
    required this.success,
    this.error,
    this.document,
  });

  factory CheckInSyncResult.ok(CheckInDocument document) {
    return CheckInSyncResult._(success: true, document: document);
  }

  factory CheckInSyncResult.fail(String error) {
    return CheckInSyncResult._(success: false, error: error);
  }
}

/// 打卡数据同步编排
class CheckInSyncService {
  CheckInDocument _document = CheckInDocument.empty;
  bool _loading = false;
  bool _syncing = false;
  String? _lastError;

  /// Serializes async operations to prevent concurrent mutation of _document.
  Future<void>? _pendingOperation;

  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final prev = _pendingOperation;
    final completer = Completer<void>();
    _pendingOperation = completer.future;
    try {
      if (prev != null) await prev;
      return await action();
    } finally {
      completer.complete();
    }
  }

  CheckInDocument get document => _document;
  bool get loading => _loading;
  bool get syncing => _syncing;
  String? get lastError => _lastError;

  List<CheckInGoal> get goalsWithRecords => _document.goalsWithRecords();

  /// Windows 手动身份派生的打卡用户（仅 Windows 使用）
  GoogleCalendarUser? _manualUser;

  GoogleCalendarUser? get currentUser => isDesktopPlatform
      ? (_manualUser ?? AppIdentityService.currentUser)
      : AppIdentityService.currentUser;

  /// 是否已识别用户（含曾登录但日历 token 暂时失效）
  bool get hasIdentity => currentUser != null;

  /// 日历是否在线（与打卡身份无关）
  bool get isCalendarOnline =>
      AppIdentityService.isGoogleMode && GoogleCalendarService.isSignedIn;

  /// 初始化：读本地 → 拉远端 → 合并
  Future<void> initialize({bool silent = false}) async {
    if (!silent) _loading = true;
    _lastError = null;
    try {
      await AppIdentityService.load();
      // Windows 无 Google 登录，打卡身份来自手动选择的角色
      if (isDesktopPlatform) {
        _manualUser = await _loadManualUser();
      } else if (AppIdentityService.isGoogleMode &&
          AppIdentityService.personKind != null) {
        // 手动模式不应因为进入打卡页而触发 Google 恢复。
        unawaited(GoogleCalendarService.restoreSignIn(background: true));
      }

      final local = await CheckInLocalStore.loadDraft();
      if (local != null) _document = local;

      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) {
        // 没有远端可比较时不要补时间戳；之后用户配置 token 后，远端可能已有
        // 比旧本地数据更新的目标，必须保留 updatedAt=0 让合并策略安全处理。
        return;
      }

      final pull = await CheckInGiteeService.pullText(
        token: token,
        path: CheckInDocument.filePath,
      );

      if (pull.success && pull.content != null) {
        try {
          final remote = CheckInDocument.fromMarkdown(pull.content!);
          final merged =
              local == null ? remote : CheckInDocument.merge(local, remote);
          // 先合并，再给最终选中的旧目标补时间戳，避免陈旧本地目标覆盖远端新版本。
          _document = await _migrateLegacyGoalTimestamps(merged);
          await CheckInLocalStore.saveDraft(_document);
        } catch (e) {
          _lastError = '解析远端打卡数据失败: $e';
        }
      } else if (pull.notFound && local != null) {
        // 远端文件确认不存在时，本地目标没有远端新版本可冲突。
        _document = await _migrateLegacyGoalTimestamps(local);
      }
    } finally {
      if (!silent) _loading = false;
    }
  }

  /// 给已经完成同步决策的旧目标补齐时间戳并落盘（保证跨重启稳定）。
  ///
  /// 旧目标的时间戳未知，不能在拉取远端前把它当成最新修改；只有远端不存在，
  /// 或本地/远端已完成合并后，才可以把最终选中的内容作为新的基线保存。
  Future<CheckInDocument> _migrateLegacyGoalTimestamps(
    CheckInDocument doc,
  ) async {
    final migrated =
        doc.withLegacyGoalTimestamps(DateTime.now().millisecondsSinceEpoch);
    if (identical(migrated, doc)) return doc;
    await CheckInLocalStore.saveDraft(migrated);
    return migrated;
  }

  Future<CheckInSyncResult> pullFromGitHub() async {
    return _synchronized(() async {
      _syncing = true;
      _lastError = null;
      try {
        final token = await _requireToken();
        if (token == null) {
          return CheckInSyncResult.fail('未配置当前平台同步 Token');
        }

        final pull = await CheckInGiteeService.pullText(
          token: token,
          path: CheckInDocument.filePath,
        );
        if (pull.notFound) {
          // 远端尚无该文件（也可能是路径被解析成目录或缺权限被误判为 notFound）。
          // 一律保留本地数据，绝不清空本地。
          return CheckInSyncResult.ok(_document);
        }
        if (!pull.success || pull.content == null) {
          return CheckInSyncResult.fail(pull.error ?? '拉取失败');
        }

        final remote = CheckInDocument.fromMarkdown(pull.content!);
        _document = CheckInDocument.merge(_document, remote);
        await CheckInLocalStore.saveDraft(_document);
        return CheckInSyncResult.ok(_document);
      } catch (e) {
        return CheckInSyncResult.fail('拉取失败: $e');
      } finally {
        _syncing = false;
      }
    });
  }

  Future<CheckInSyncResult> pushToGitHub() async {
    return _synchronized(() async {
      _syncing = true;
      _lastError = null;
      try {
        return await _pushToGitHubInternal();
      } catch (e) {
        return CheckInSyncResult.fail('同步失败: $e');
      } finally {
        _syncing = false;
      }
    });
  }

  /// 写操作（推送/删除）前先拉取远端并合并进 [_document]。
  ///
  /// [error] 非 null 表示远端不可读或格式异常，调用方必须中止本次写操作，
  /// 绝不能用本地内容覆盖远端。[sha] / [notFound] 是这次读取到的远端版本，
  /// 应原样交给随后的写入做乐观并发校验。
  Future<({String? error, String? sha, bool notFound})> _pullAndMergeForWrite(
    String token,
  ) async {
    final pull = await CheckInGiteeService.pullText(
      token: token,
      path: CheckInDocument.filePath,
    );
    if (pull.notFound) {
      return (error: null, sha: null, notFound: true);
    }
    if (!pull.success || pull.content == null) {
      return (
        error: '远端读取失败，已中止同步：${pull.error ?? '未知错误'}',
        sha: null,
        notFound: false,
      );
    }
    try {
      final remote = CheckInDocument.fromMarkdown(pull.content!);
      _document = CheckInDocument.merge(_document, remote);
    } catch (e) {
      return (
        error: '远端打卡数据格式异常，已中止同步以保护数据：$e',
        sha: null,
        notFound: false,
      );
    }
    return (error: null, sha: pull.sha, notFound: false);
  }

  Future<CheckInSyncResult> _pushToGitHubInternal() async {
    final token = await _requireToken();
    if (token == null) {
      return CheckInSyncResult.fail('未配置当前平台同步 Token');
    }

    // 先拉远端合并，避免覆盖对方的打卡
    final pull = await _pullAndMergeForWrite(token);
    if (pull.error != null) {
      return CheckInSyncResult.fail(pull.error!);
    }

    final userLabel = currentUser?.label ?? '?';
    final push = await CheckInGiteeService.pushText(
      token: token,
      path: CheckInDocument.filePath,
      content: _document.toMarkdown(),
      commitMessage: 'check-in($userLabel): update data',
      expectedSha: pull.sha,
      expectNotFound: pull.notFound,
    );
    if (!push.success) {
      return CheckInSyncResult.fail(push.error ?? '推送失败');
    }

    await CheckInLocalStore.saveDraft(_document);
    return CheckInSyncResult.ok(_document);
  }

  Future<CheckInSyncResult> saveGoal(CheckInGoal goal) async {
    final user = await _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先选择乖乖或晶晶，或完成 Google 登录');
    }

    final meta = goal.copyWith(
      ownerId: goal.ownerId.isEmpty ? user.id : goal.ownerId,
      ownerEmail: goal.ownerEmail.isEmpty ? user.email : goal.ownerEmail,
      ownerDisplayName: goal.ownerDisplayName ?? user.displayName,
      records: const [],
      // 打上修改时间，合并时才能胜出；否则会被远端旧元数据覆盖。
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    _document = _document.upsertGoal(meta);
    await CheckInLocalStore.saveDraft(_document);
    return pushToGitHub();
  }

  Future<CheckInSyncResult> deleteGoal(CheckInGoal goal) async {
    final user = await _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先选择乖乖或晶晶，或完成 Google 登录');
    }
    if (!goal.isOwnedBy(user.id, email: user.email)) {
      return CheckInSyncResult.fail('只能删除自己创建的目标');
    }

    return _synchronized(() async {
      _syncing = true;
      _lastError = null;
      try {
        final token = await _requireToken();
        if (token == null) {
          return CheckInSyncResult.fail('未配置当前平台同步 Token');
        }

        final pull = await _pullAndMergeForWrite(token);
        if (pull.error != null) {
          return CheckInSyncResult.fail(pull.error!);
        }

        _document = _document.tombstoneGoal(goal.id);
        await CheckInLocalStore.saveDraft(_document);

        final push = await CheckInGiteeService.pushText(
          token: token,
          path: CheckInDocument.filePath,
          content: _document.toMarkdown(),
          commitMessage: 'check-in(${user.label}): delete goal ${goal.name}',
          expectedSha: pull.sha,
          expectNotFound: pull.notFound,
        );
        if (!push.success) {
          return CheckInSyncResult.fail(push.error ?? '删除同步失败');
        }

        return CheckInSyncResult.ok(_document);
      } catch (e) {
        return CheckInSyncResult.fail('删除失败: $e');
      } finally {
        _syncing = false;
      }
    });
  }

  Future<CheckInSyncResult> deleteCheckInRecord(
    CheckInGoal goal,
    CheckInRecord record,
  ) async {
    final user = await _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先选择乖乖或晶晶，或完成 Google 登录');
    }
    if (!record.belongsTo(user.id, user.email)) {
      return CheckInSyncResult.fail('只能删除自己的打卡记录');
    }

    return _synchronized(() async {
      _syncing = true;
      _lastError = null;
      try {
        final token = await _requireToken();
        if (token == null) {
          return CheckInSyncResult.fail('未配置当前平台同步 Token');
        }

        // Step 1: Pull remote and merge to avoid overwriting others' data
        final pull = await _pullAndMergeForWrite(token);
        if (pull.error != null) {
          return CheckInSyncResult.fail(pull.error!);
        }

        // Step 2: Remove record from document
        _document = _document.tombstoneRecord(record.id);

        // Step 3: Save locally
        await CheckInLocalStore.saveDraft(_document);

        // Step 4: Push updated document to Gitee. The document version check must
        // succeed before deleting the photo; otherwise a concurrent write could
        // leave the remote document pointing at a photo that was already removed.
        final push = await CheckInGiteeService.pushText(
          token: token,
          path: CheckInDocument.filePath,
          content: _document.toMarkdown(),
          commitMessage: 'check-in(${user.label}): delete record ${record.id}',
          expectedSha: pull.sha,
          expectNotFound: pull.notFound,
        );
        if (!push.success) {
          return CheckInSyncResult.fail(push.error ?? '删除同步失败');
        }

        // Step 5: Delete the now-unreferenced photo from Gitee. Failure here is
        // best-effort: an orphaned photo is safer than a broken remote record.
        if (record.photoPath != null && record.photoPath!.isNotEmpty) {
          await CheckInGiteeService.deleteFile(
            token: token,
            path: record.photoPath!,
            commitMessage:
                'check-in(${user.label}): delete photo ${record.photoPath}',
          );
          // Also remove local cache (best-effort, ignore errors)
          try {
            final cached =
                await CheckInPhotoCache.getCachedFile(record.photoPath!);
            if (cached != null && await cached.exists()) {
              await cached.delete();
            }
          } catch (_) {}
        }

        return CheckInSyncResult.ok(_document);
      } catch (e) {
        return CheckInSyncResult.fail('删除失败: $e');
      } finally {
        _syncing = false;
      }
    });
  }

  Future<CheckInSyncResult> submitCheckIn({
    required CheckInGoal goal,
    File? photoFile,
    CheckInLocationResult? location,
    DateTime? backfillDate,
    bool isBackfill = false,
  }) async {
    final user = await _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先选择乖乖或晶晶，或完成 Google 登录');
    }

    final now = DateTime.now();
    final effectiveDate = backfillDate ?? now;
    // 不能补打未来日期
    if (effectiveDate.isAfter(now)) {
      return CheckInSyncResult.fail('不能补打未来日期');
    }

    return _synchronized(() async {
      _syncing = true;
      try {
        final recordId = now.millisecondsSinceEpoch.toString();
        String? photoPath;

        // 有照片时：压缩并上传
        if (photoFile != null) {
          final token = await _requireToken();
          if (token == null) {
            return CheckInSyncResult.fail('未配置当前平台同步 Token，无法上传照片');
          }

          photoPath = CheckInDocument.imagePathFor(
            userEmail: user.email,
            recordId: recordId,
          );

          final compressed = await CheckInImageService.compressFile(photoFile);
          if (compressed == null || compressed.isEmpty) {
            return CheckInSyncResult.fail('照片压缩失败');
          }

          // Photo is a new file, skip GET sha to save one HTTP request
          final imagePush = await CheckInGiteeService.pushBinary(
            token: token,
            path: photoPath,
            bytes: compressed,
            commitMessage: 'check-in(${user.label}): photo $recordId',
            skipGetSha: true,
          );
          if (!imagePush.success) {
            return CheckInSyncResult.fail(imagePush.error ?? '照片上传失败');
          }

          await CheckInPhotoCache.saveBytes(photoPath, compressed);
        }

        final record = CheckInRecord(
          id: recordId,
          goalId: goal.id,
          userId: user.id,
          userEmail: user.email,
          userDisplayName: user.displayName ?? user.label,
          timestamp: effectiveDate,
          latitude: location?.latitude,
          longitude: location?.longitude,
          locationName: location?.locationName,
          photoPath: photoPath,
          isBackfill: isBackfill,
        );

        _document = _document.upsertRecord(record);
        await CheckInLocalStore.saveDraft(_document);

        final metaResult = await _pushToGitHubInternal();
        return metaResult;
      } catch (e) {
        return CheckInSyncResult.fail('打卡失败: $e');
      } finally {
        _syncing = false;
      }
    });
  }

  Future<File?> loadPhoto(String photoPath) async {
    final token = await _requireToken();
    if (token == null) return CheckInPhotoCache.getCachedFile(photoPath);
    return CheckInPhotoCache.loadOrFetch(token: token, photoPath: photoPath);
  }

  Future<String?> _requireToken() async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<GoogleCalendarUser?> _requireUser() async {
    if (isDesktopPlatform) {
      _manualUser ??= await _loadManualUser();
      return _manualUser ?? AppIdentityService.currentUser;
    }
    return AppIdentityService.currentUser;
  }

  /// 从手动身份派生打卡用户，保证跨设备稳定且照片目录与安卓一致
  Future<GoogleCalendarUser?> _loadManualUser() async {
    final kind = await AppUserIdentityStore.loadManualKind();
    if (kind == null) return null;
    switch (kind) {
      case DiaryKind.g:
        return GoogleCalendarUser(
          email: KnownGoogleUsers.guaiGuaiEmail,
          id: 'manual-g',
          displayName: '乖乖',
        );
      case DiaryKind.j:
        return GoogleCalendarUser(
          email: KnownGoogleUsers.jingJingEmail,
          id: 'manual-j',
          displayName: '晶晶',
        );
    }
  }
}
