import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

import '../models/app_log_entry.dart';
import 'app_log_service.dart';

class AppLogExportResult {
  const AppLogExportResult._({
    required this.cancelled,
    required this.success,
    this.path,
    this.error,
  });

  factory AppLogExportResult.cancelled() =>
      const AppLogExportResult._(cancelled: true, success: false);

  factory AppLogExportResult.success([String? path]) =>
      AppLogExportResult._(cancelled: false, success: true, path: path);

  factory AppLogExportResult.error(String message) => AppLogExportResult._(
        cancelled: false,
        success: false,
        error: message,
      );

  final bool cancelled;
  final bool success;
  final String? path;
  final String? error;
}

class AppLogExportService {
  static const _dateFormat = 'yyyy-MM-dd HH:mm:ss.SSS';

  static String format(
    Iterable<AppLogEntry> entries, {
    DateTime? exportedAt,
  }) {
    final formatter = DateFormat(_dateFormat);
    final entriesList = entries.toList(growable: false);
    final buffer = StringBuffer()
      ..writeln('TimeManager 运行日志')
      ..writeln(
          '导出时间：${formatter.format((exportedAt ?? DateTime.now()).toLocal())}')
      ..writeln('日志数量：${entriesList.length}')
      ..writeln();

    for (var index = 0; index < entriesList.length; index++) {
      final entry = entriesList[index];
      buffer
        ..writeln(
          '[${entry.level.label}] [${entry.source}] ${entry.message}',
        )
        ..writeln('时间：${formatter.format(entry.localTimestamp)}');
      if (entry.error != null && entry.error!.isNotEmpty) {
        buffer.writeln('异常：${entry.error}');
      }
      if (entry.stackTrace != null && entry.stackTrace!.isNotEmpty) {
        buffer
          ..writeln('堆栈：')
          ..writeln(entry.stackTrace);
      }
      if (index != entriesList.length - 1) buffer.writeln();
    }

    return buffer.toString();
  }

  static Future<AppLogExportResult> export(
    Iterable<AppLogEntry> entries,
  ) async {
    try {
      final fileName =
          'time_manager_logs_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.txt';
      final path = await FilePicker.saveFile(
        dialogTitle: '导出运行日志',
        fileName: fileName,
        bytes: utf8.encode(format(entries)),
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );

      if (path == null) return AppLogExportResult.cancelled();
      AppLogService.instance.info('运行日志导出成功', source: 'app_log_export');
      return AppLogExportResult.success(path);
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '运行日志导出失败',
        source: 'app_log_export',
        error: error,
        stackTrace: stackTrace,
      );
      return AppLogExportResult.error('导出日志失败: $error');
    }
  }
}
