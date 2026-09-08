import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

import '../providers/time_provider.dart';
import 'app_log_service.dart';

class BackupFileResult {
  final bool cancelled;
  final bool success;
  final String? path;
  final String? error;

  const BackupFileResult._({
    required this.cancelled,
    required this.success,
    this.path,
    this.error,
  });

  factory BackupFileResult.cancelled() =>
      const BackupFileResult._(cancelled: true, success: false);

  factory BackupFileResult.success([String? path]) =>
      BackupFileResult._(cancelled: false, success: true, path: path);

  factory BackupFileResult.error(String message) =>
      BackupFileResult._(cancelled: false, success: false, error: message);
}

class DataBackupService {
  static Future<BackupFileResult> exportToFile(TimeProvider provider) async {
    try {
      final jsonStr = provider.exportBackupJson();
      final fileName =
          'time_manager_backup_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.json';

      final path = await FilePicker.saveFile(
        dialogTitle: '导出备份',
        fileName: fileName,
        bytes: utf8.encode(jsonStr),
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (path == null) {
        return BackupFileResult.cancelled();
      }
      AppLogService.instance.info('备份导出成功', source: 'backup');
      return BackupFileResult.success(path);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        '备份导出失败',
        source: 'backup',
        error: e,
        stackTrace: stackTrace,
      );
      return BackupFileResult.error('导出失败: $e');
    }
  }

  static Future<
          ({BackupFileResult result, BackupPreview? preview, String? json})>
      pickBackupFile(TimeProvider provider) async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );

      if (picked == null || picked.files.isEmpty) {
        return (
          result: BackupFileResult.cancelled(),
          preview: null,
          json: null
        );
      }

      final bytes = picked.files.first.bytes;
      if (bytes == null || bytes.isEmpty) {
        AppLogService.instance.warning(
          '备份文件内容为空或无法读取',
          source: 'backup',
        );
        return (
          result: BackupFileResult.error('无法读取文件内容'),
          preview: null,
          json: null,
        );
      }

      final jsonStr = utf8.decode(bytes);
      final preview = provider.previewBackupJson(jsonStr);
      if (preview == null) {
        AppLogService.instance.warning(
          '备份文件格式无效',
          source: 'backup',
        );
        return (
          result: BackupFileResult.error('不是有效的时间块备份文件'),
          preview: null,
          json: null,
        );
      }

      return (
        result: BackupFileResult.success(),
        preview: preview,
        json: jsonStr
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        '选择备份文件失败',
        source: 'backup',
        error: e,
        stackTrace: stackTrace,
      );
      return (
        result: BackupFileResult.error('选择备份文件失败: $e'),
        preview: null,
        json: null,
      );
    }
  }

  static Future<BackupFileResult> importFromJson(
    TimeProvider provider,
    String jsonStr,
  ) async {
    try {
      await provider.importBackupJson(jsonStr);
      AppLogService.instance.info('备份导入成功', source: 'backup');
      return BackupFileResult.success();
    } on FormatException catch (e, stackTrace) {
      AppLogService.instance.warning(
        '备份导入格式无效',
        source: 'backup',
        error: e,
        stackTrace: stackTrace,
      );
      return BackupFileResult.error(e.message);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        '备份导入失败',
        source: 'backup',
        error: e,
        stackTrace: stackTrace,
      );
      return BackupFileResult.error('导入失败: $e');
    }
  }
}
