import 'dart:async';
import 'dart:io';

import '../models/check_in_document.dart';
import '../models/check_in_goal.dart';
import '../models/check_in_record.dart';
import '../models/google_calendar_user.dart';
import 'check_in_gitee_service.dart';
import 'check_in_image_service.dart';
import 'check_in_local_store.dart';
import 'check_in_location_service.dart';
import 'check_in_photo_cache.dart';
import 'diary_local_store.dart';
import 'google_calendar_service.dart';

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

  GoogleCalendarUser? get currentUser => GoogleCalendarService.sessionUser;

  /// 是否已识别用户（含曾登录但日历 token 暂时失效）
  bool get hasIdentity => GoogleCalendarService.hasKnownUser;

  /// 日历是否在线（与打卡身份无关）
  bool get isCalendarOnline => GoogleCalendarService.isSignedIn;

  /// 初始化：读本地 → 拉远端 → 合并
  Future<void> initialize({bool silent = false}) async {
    if (!silent) _loading = true;
    _lastError = null;
    try {
      final local = await CheckInLocalStore.loadDraft();
      if (local != null) _document = local;

      final token = await DiaryLocalStore.loadToken();
      if (token == null || token.isEmpty) {
        return;
      }

      final pull = await CheckInGiteeService.pullText(
        token: token,
        path: CheckInDocument.filePath,
      );

      if (pull.success && pull.content != null) {
        try {
          final remote = CheckInDocument.fromMarkdown(pull.content!);
          _document = local == null
              ? remote
              : CheckInDocument.merge(local, remote);
          await CheckInLocalStore.saveDraft(_document);
        } catch (e) {
          _lastError = '解析远端打卡数据失败: $e';
        }
      }
    } finally {
      if (!silent) _loading = false;
    }
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
          _document = CheckInDocument.empty;
          await CheckInLocalStore.saveDraft(_document);
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
      } finally {
        _syncing = false;
      }
    });
  }

  Future<CheckInSyncResult> _pushToGitHubInternal() async {
    final token = await _requireToken();
    if (token == null) {
      return CheckInSyncResult.fail('未配置当前平台同步 Token');
    }

    print('[pushToGitHub] 推送前本地文档记录数=${_document.records.length}');

    // 先拉远端合并，避免覆盖对方的打卡
    final pull = await CheckInGiteeService.pullText(
      token: token,
      path: CheckInDocument.filePath,
    );
    if (pull.success && pull.content != null) {
      final remote = CheckInDocument.fromMarkdown(pull.content!);
      print(
          '[pushToGitHub] 拉取远端成功, 远端记录数=${remote.records.length}');
      _document = CheckInDocument.merge(_document, remote);
      print(
          '[pushToGitHub] 合并后文档记录数=${_document.records.length}');
    } else {
      print(
          '[pushToGitHub] 拉取远端: success=${pull.success}, '
          'hasContent=${pull.content != null}');
    }

    final userLabel = currentUser?.label ?? '?';
    final push = await CheckInGiteeService.pushText(
      token: token,
      path: CheckInDocument.filePath,
      content: _document.toMarkdown(),
      commitMessage: 'check-in($userLabel): update data',
    );
    if (!push.success) {
      return CheckInSyncResult.fail(push.error ?? '推送失败');
    }

    await CheckInLocalStore.saveDraft(_document);
    return CheckInSyncResult.ok(_document);
  }

  Future<CheckInSyncResult> saveGoal(CheckInGoal goal) async {
    final user = _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先至少登录一次 Google 以识别身份');
    }

    final meta = goal.copyWith(
      ownerId: goal.ownerId.isEmpty ? user.id : goal.ownerId,
      ownerEmail: goal.ownerEmail.isEmpty ? user.email : goal.ownerEmail,
      ownerDisplayName: goal.ownerDisplayName ?? user.displayName,
      records: const [],
    );

    _document = _document.upsertGoal(meta);
    await CheckInLocalStore.saveDraft(_document);
    return pushToGitHub();
  }

  Future<CheckInSyncResult> deleteGoal(CheckInGoal goal) async {
    final user = _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先至少登录一次 Google 以识别身份');
    }
    if (!goal.isOwnedBy(user.id)) {
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

        final pull = await CheckInGiteeService.pullText(
          token: token,
          path: CheckInDocument.filePath,
        );
        if (pull.success && pull.content != null) {
          final remote = CheckInDocument.fromMarkdown(pull.content!);
          _document = CheckInDocument.merge(_document, remote);
        }

        _document = _document.removeGoal(goal.id);
        await CheckInLocalStore.saveDraft(_document);

        final push = await CheckInGiteeService.pushText(
          token: token,
          path: CheckInDocument.filePath,
          content: _document.toMarkdown(),
          commitMessage: 'check-in(${user.label}): delete goal ${goal.name}',
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
    final user = _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先至少登录一次 Google 以识别身份');
    }
    if (record.userId != user.id) {
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
      final pull = await CheckInGiteeService.pullText(
        token: token,
        path: CheckInDocument.filePath,
      );
      if (pull.success && pull.content != null) {
        final remote = CheckInDocument.fromMarkdown(pull.content!);
        _document = CheckInDocument.merge(_document, remote);
      }

      // Step 2: Delete photo from GitHub if present
      if (record.photoPath != null && record.photoPath!.isNotEmpty) {
        await CheckInGiteeService.deleteFile(
          token: token,
          path: record.photoPath!,
          commitMessage: 'check-in(${user.label}): delete photo ${record.photoPath}',
        );
        // Also remove local cache (best-effort, ignore errors)
        try {
          final cached = await CheckInPhotoCache.getCachedFile(record.photoPath!);
          if (cached != null && await cached.exists()) {
            await cached.delete();
          }
        } catch (_) {}
      }

      // Step 3: Remove record from document
      _document = _document.removeRecord(record.id);

      // Step 4: Save locally
      await CheckInLocalStore.saveDraft(_document);

      // Step 5: Push updated document to GitHub
      final push = await CheckInGiteeService.pushText(
        token: token,
        path: CheckInDocument.filePath,
        content: _document.toMarkdown(),
        commitMessage: 'check-in(${user.label}): delete record ${record.id}',
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

  Future<CheckInSyncResult> submitCheckIn({
    required CheckInGoal goal,
    File? photoFile,
    CheckInLocationResult? location,
    DateTime? backfillDate,
    bool isBackfill = false,
  }) async {
    final user = _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先至少登录一次 Google 以识别身份');
    }

    final now = DateTime.now();
    final effectiveDate = backfillDate ?? now;

    print(
        '[submitCheckIn] 入口: backfillDate=${backfillDate?.toIso8601String()}, '
        'effectiveDate=${effectiveDate.toIso8601String()}, '
        'isBackfill=$isBackfill, hasPhoto=${photoFile != null}');
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

      print(
          '[submitCheckIn] 新建记录: id=$recordId, '
          'timestamp=${effectiveDate.toIso8601String()}, '
          'isBackfill=$isBackfill, hasPhoto=${photoFile != null}');

      _document = _document.upsertRecord(record);
      await CheckInLocalStore.saveDraft(_document);

      print(
          '[submitCheckIn] upsert 后本地文档记录数=${_document.records.length}, '
          '记录 id=$recordId isBackfill=${_document.records.firstWhere((r) => r.id == recordId).isBackfill}');

      final metaResult = await _pushToGitHubInternal();
      print(
          '[submitCheckIn] push 后文档记录数=${_document.records.length}, '
          '记录 id=$recordId isBackfill=${_document.records.firstWhere((r) => r.id == recordId).isBackfill}');
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

  GoogleCalendarUser? _requireUser() => GoogleCalendarService.sessionUser;
}
