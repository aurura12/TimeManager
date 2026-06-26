import 'dart:io';

import '../models/check_in_document.dart';
import '../models/check_in_goal.dart';
import '../models/check_in_record.dart';
import '../models/google_calendar_user.dart';
import 'check_in_github_service.dart';
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

    final local = await CheckInLocalStore.loadDraft();
    if (local != null) _document = local;

    final token = await DiaryLocalStore.loadToken();
    if (token == null || token.isEmpty) {
      if (!silent) _loading = false;
      return;
    }

    final pull = await CheckInGitHubService.pullText(
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

    if (!silent) _loading = false;
  }

  Future<CheckInSyncResult> pullFromGitHub() async {
    _syncing = true;
    _lastError = null;
    try {
      final token = await _requireToken();
      if (token == null) {
        return CheckInSyncResult.fail('未配置 GitHub Token');
      }

      final pull = await CheckInGitHubService.pullText(
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
  }

  Future<CheckInSyncResult> pushToGitHub() async {
    _syncing = true;
    _lastError = null;
    try {
      final token = await _requireToken();
      if (token == null) {
        return CheckInSyncResult.fail('未配置 GitHub Token');
      }

      // 先拉远端合并，避免覆盖对方的打卡
      final pull = await CheckInGitHubService.pullText(
        token: token,
        path: CheckInDocument.filePath,
      );
      if (pull.success && pull.content != null) {
        final remote = CheckInDocument.fromMarkdown(pull.content!);
        _document = CheckInDocument.merge(_document, remote);
      }

      final push = await CheckInGitHubService.pushText(
        token: token,
        path: CheckInDocument.filePath,
        content: _document.toMarkdown(),
        commitMessage: 'check-in: update data',
      );
      if (!push.success) {
        return CheckInSyncResult.fail(push.error ?? '推送失败');
      }

      await CheckInLocalStore.saveDraft(_document);
      return CheckInSyncResult.ok(_document);
    } catch (e) {
      return CheckInSyncResult.fail('推送失败: $e');
    } finally {
      _syncing = false;
    }
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

  Future<CheckInSyncResult> submitCheckIn({
    required CheckInGoal goal,
    required File photoFile,
    CheckInLocationResult? location,
  }) async {
    final user = _requireUser();
    if (!hasIdentity || user == null) {
      return CheckInSyncResult.fail('请先至少登录一次 Google 以识别身份');
    }

    final token = await _requireToken();
    if (token == null) {
      return CheckInSyncResult.fail('未配置 GitHub Token，无法上传照片');
    }

    _syncing = true;
    try {
      final recordId = DateTime.now().millisecondsSinceEpoch.toString();
      final photoPath = CheckInDocument.imagePathFor(
        userId: user.id,
        recordId: recordId,
      );

      final compressed = await CheckInImageService.compressFile(photoFile);
      if (compressed == null || compressed.isEmpty) {
        return CheckInSyncResult.fail('照片压缩失败');
      }

      final imagePush = await CheckInGitHubService.pushBinary(
        token: token,
        path: photoPath,
        bytes: compressed,
        commitMessage: 'check-in: photo $recordId',
      );
      if (!imagePush.success) {
        return CheckInSyncResult.fail(imagePush.error ?? '照片上传失败');
      }

      await CheckInPhotoCache.saveBytes(photoPath, compressed);

      final record = CheckInRecord(
        id: recordId,
        goalId: goal.id,
        userId: user.id,
        userEmail: user.email,
        userDisplayName: user.displayName ?? user.label,
        timestamp: DateTime.now(),
        latitude: location?.latitude,
        longitude: location?.longitude,
        locationName: location?.locationName,
        photoPath: photoPath,
      );

      _document = _document.upsertRecord(record);
      await CheckInLocalStore.saveDraft(_document);

      final metaResult = await pushToGitHub();
      return metaResult;
    } catch (e) {
      return CheckInSyncResult.fail('打卡失败: $e');
    } finally {
      _syncing = false;
    }
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
