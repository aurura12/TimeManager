import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

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
import 'check_in_photo_resource.dart';
import 'diary_local_store.dart';
import 'google_calendar_service.dart';
import 'app_identity_service.dart';
import '../utils/platform_features.dart';

class CheckInSyncResult {
  final bool success;
  final String? error;
  final String? warning;
  final CheckInDocument? document;

  const CheckInSyncResult._({
    required this.success,
    this.error,
    this.warning,
    this.document,
  });

  factory CheckInSyncResult.ok(
    CheckInDocument document, {
    String? warning,
  }) {
    return CheckInSyncResult._(
      success: true,
      document: document,
      warning: warning,
    );
  }

  factory CheckInSyncResult.fail(String error) {
    return CheckInSyncResult._(success: false, error: error);
  }
}

/// 打卡数据同步编排
class CheckInSyncService {
  static const _pendingPhotoCleanupKey = 'check_in_pending_photo_cleanup_v1';

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

  /// 保存/编辑目标前的业务校验。必须在服务层执行，不能只依赖页面上的按钮状态。
  static String? validateGoalMutation({
    required CheckInGoal goal,
    required CheckInDocument document,
    required String userId,
    required String userEmail,
  }) {
    final start = goal.startDate;
    final end = goal.endDate;
    if (start != null &&
        end != null &&
        DateTime(end.year, end.month, end.day)
            .isBefore(DateTime(start.year, start.month, start.day))) {
      return '结束日期不能早于开始日期';
    }

    final existing = document.goals.where((g) => g.id == goal.id).firstOrNull;
    if (existing != null && !existing.isOwnedBy(userId, email: userEmail)) {
      return '只能修改自己创建的目标';
    }

    // 新建目标通常没有 owner 字段；若调用方显式携带了归属，则也必须属于当前
    // 逻辑身份，避免通过服务层直接伪造他人的目标。
    final hasOwner =
        goal.ownerId.trim().isNotEmpty || goal.ownerEmail.trim().isNotEmpty;
    if (existing == null &&
        hasOwner &&
        !goal.isOwnedBy(userId, email: userEmail)) {
      return '目标归属与当前身份不一致';
    }
    return null;
  }

  /// 提交打卡前的统一规则校验。
  ///
  /// [existingRecords] 应来自服务当前文档，而不是仅来自页面传入的旧快照，
  /// 这样同一账号在另一台设备上刚打过卡时也不会被本地页面绕过。
  static String? validateCheckInRequest({
    required CheckInGoal goal,
    required Iterable<CheckInRecord> existingRecords,
    required String userId,
    required String userEmail,
    required DateTime now,
    DateTime? backfillDate,
    bool hasPhoto = true,
    bool hasLocation = true,
  }) {
    if (!goal.isOwnedBy(userId, email: userEmail)) {
      return '只能在自己的目标下打卡';
    }
    if (goal.isArchived) return '已归档的目标不能打卡';

    final effectiveDate = backfillDate ?? now;
    if (effectiveDate.isAfter(now)) return '不能补打未来日期';
    if (!goal.allowsCheckInAt(effectiveDate)) {
      final start = goal.startDate;
      if (start != null &&
          DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day)
              .isBefore(DateTime(start.year, start.month, start.day))) {
        return '目标尚未开始，不能打卡';
      }
      return '已超过目标结束日期，不能打卡';
    }

    if (goal.requirePhoto && !hasPhoto) return '请先添加打卡照片';
    if (goal.requireLocation && !hasLocation) return '请先获取打卡位置';

    final duplicate = existingRecords.any(
      (record) =>
          record.goalId == goal.id &&
          record.belongsTo(userId, userEmail) &&
          _isSameLocalDay(record.timestamp, effectiveDate),
    );
    if (duplicate) return '这一天已经打卡，不能重复补打卡';
    return null;
  }

  static bool _isSameLocalDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

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

      // 目标删除成功但照片清理失败时，保留的路径会在后续启动自动重试。
      unawaited(retryPendingPhotoCleanup());
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
    return _synchronized(() async {
      _syncing = true;
      _lastError = null;
      try {
        final user = await _requireUser();
        if (!hasIdentity || user == null) {
          return CheckInSyncResult.fail('请先选择乖乖或晶晶，或完成 Google 登录');
        }

        // 先合并远端，再做归属校验，避免旧页面快照覆盖远端的他人目标。
        final token = await _requireToken();
        if (token != null) {
          final pull = await _pullAndMergeForWrite(token);
          if (pull.error != null) return CheckInSyncResult.fail(pull.error!);
        }

        final validation = validateGoalMutation(
          goal: goal,
          document: _document,
          userId: user.id,
          userEmail: user.email,
        );
        if (validation != null) return CheckInSyncResult.fail(validation);

        final meta = goal.copyWith(
          // 统一保存为当前身份的 id + email；查询端仍会通过 email 兼容另一种
          // 身份模式下已经存在的历史记录。
          ownerId: user.id,
          ownerEmail: user.email,
          ownerDisplayName: goal.ownerDisplayName ?? user.displayName,
          records: const [],
          // 打上修改时间，合并时才能胜出；否则会被远端旧元数据覆盖。
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );

        _document = _document.upsertGoal(meta);
        await CheckInLocalStore.saveDraft(_document);
        return await _pushToGitHubInternal();
      } catch (e) {
        return CheckInSyncResult.fail('保存失败: $e');
      } finally {
        _syncing = false;
      }
    });
  }

  Future<CheckInSyncResult> deleteGoal(CheckInGoal goal) async {
    return _synchronized(() async {
      _syncing = true;
      _lastError = null;
      try {
        final user = await _requireUser();
        if (!hasIdentity || user == null) {
          return CheckInSyncResult.fail('请先选择乖乖或晶晶，或完成 Google 登录');
        }
        final token = await _requireToken();
        if (token == null) {
          return CheckInSyncResult.fail('未配置当前平台同步 Token');
        }

        final pull = await _pullAndMergeForWrite(token);
        if (pull.error != null) {
          return CheckInSyncResult.fail(pull.error!);
        }

        final liveGoal =
            _document.goals.where((g) => g.id == goal.id).firstOrNull;
        if (liveGoal == null) return CheckInSyncResult.fail('目标不存在或已被删除');
        if (!liveGoal.isOwnedBy(user.id, email: user.email)) {
          return CheckInSyncResult.fail('只能删除自己创建的目标');
        }
        final photoPaths = _document.records
            .where((record) => record.goalId == goal.id)
            .map((record) => record.photoPath)
            .whereType<String>()
            .where((path) => path.isNotEmpty)
            .toSet();

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

        final failedPhotos = await _attemptPhotoCleanup(
          token: token,
          paths: photoPaths,
          commitPrefix: 'check-in(${user.label}): delete goal ${goal.name}',
        );
        final warning = failedPhotos.isEmpty
            ? null
            : '目标已删除，但 ${failedPhotos.length} 张关联照片清理失败，后续同步会自动重试';
        return CheckInSyncResult.ok(_document, warning: warning);
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

        final liveRecord =
            _document.records.where((item) => item.id == record.id).firstOrNull;
        if (liveRecord == null) return CheckInSyncResult.fail('打卡记录不存在或已被删除');
        if (!liveRecord.belongsTo(user.id, user.email)) {
          return CheckInSyncResult.fail('只能删除自己的打卡记录');
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
        final photoPath = liveRecord.photoPath;
        final failedPhotos = photoPath == null || photoPath.isEmpty
            ? <String>{}
            : await _attemptPhotoCleanup(
                token: token,
                paths: [photoPath],
                commitPrefix:
                    'check-in(${user.label}): delete photo $photoPath',
              );
        final warning =
            failedPhotos.isEmpty ? null : '打卡记录已删除，但照片清理失败，后续同步会自动重试';
        return CheckInSyncResult.ok(_document, warning: warning);
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

    return _synchronized(() async {
      _syncing = true;
      try {
        final now = DateTime.now();
        final token = await _requireToken();

        // 有远端文档时先合并，校验必须基于最新记录；没有 Token 时保留原有
        // 离线草稿行为，最终推送阶段会返回同步失败而不丢失本地记录。
        if (token != null) {
          final pull = await _pullAndMergeForWrite(token);
          if (pull.error != null) return CheckInSyncResult.fail(pull.error!);
        }

        final liveGoal = _document
            .goalsWithRecords()
            .where((g) => g.id == goal.id)
            .firstOrNull;
        if (liveGoal == null) return CheckInSyncResult.fail('目标不存在或已被删除');
        final validation = validateCheckInRequest(
          goal: liveGoal,
          existingRecords: _document.records,
          userId: user.id,
          userEmail: user.email,
          now: now,
          backfillDate: backfillDate,
          hasPhoto: photoFile != null,
          hasLocation: location != null,
        );
        if (validation != null) return CheckInSyncResult.fail(validation);

        final effectiveDate = backfillDate ?? now;
        final recordId = now.millisecondsSinceEpoch.toString();
        String? photoPath;

        // 有照片时：压缩并上传
        if (photoFile != null) {
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

  /// 重试此前已完成目标删除、但照片文件清理失败的任务。
  Future<CheckInSyncResult> retryPendingPhotoCleanup() async {
    return _synchronized(() async {
      _syncing = true;
      try {
        final token = await _requireToken();
        if (token == null) {
          return CheckInSyncResult.fail('未配置当前平台同步 Token');
        }
        final pending = await _loadPendingPhotoCleanup();
        if (pending.isEmpty) return CheckInSyncResult.ok(_document);
        final failed = await _attemptPhotoCleanup(
          token: token,
          paths: pending,
          commitPrefix: 'check-in: retry photo cleanup',
        );
        final warning =
            failed.isEmpty ? null : '仍有 ${failed.length} 张照片清理失败，后续同步会继续重试';
        return CheckInSyncResult.ok(_document, warning: warning);
      } finally {
        _syncing = false;
      }
    });
  }

  Future<String?> _requireToken() async {
    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<Set<String>> _loadPendingPhotoCleanup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingPhotoCleanupKey);
      if (raw == null || raw.trim().isEmpty) return <String>{};
      final decoded = json.decode(raw);
      if (decoded is! List) return <String>{};
      return decoded.whereType<String>().where(_isManagedPhotoPath).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _savePendingPhotoCleanup(Set<String> paths) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (paths.isEmpty) {
        await prefs.remove(_pendingPhotoCleanupKey);
      } else {
        await prefs.setString(
            _pendingPhotoCleanupKey, json.encode(paths.toList()));
      }
    } catch (_) {
      // 清理状态本身不能让已经成功的目标/记录删除变成失败。
    }
  }

  Future<Set<String>> _attemptPhotoCleanup({
    required String token,
    required Iterable<String> paths,
    required String commitPrefix,
  }) async {
    final allPaths = {
      ...await _loadPendingPhotoCleanup(),
      ...paths.where(_isManagedPhotoPath),
    };
    final failed = <String>{};
    for (final path in allPaths) {
      try {
        final result = await CheckInGiteeService.deleteFile(
          token: token,
          path: path,
          commitMessage: '$commitPrefix: $path',
        );
        if (!result.success) {
          failed.add(path);
          continue;
        }
        try {
          final cached = await CheckInPhotoCache.getCachedFile(path);
          if (cached != null && await cached.exists()) await cached.delete();
        } catch (_) {}
      } catch (_) {
        failed.add(path);
      }
    }
    await _savePendingPhotoCleanup(failed);
    return failed;
  }

  static bool _isManagedPhotoPath(String path) {
    return CheckInPhotoResource.normalizePath(path) != null;
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
