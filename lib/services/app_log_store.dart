import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

abstract interface class AppLogStore {
  Future<List<String>> readLines();

  Future<void> appendLine(String line);

  Future<void> rewriteLines(List<String> lines);

  Future<void> clear();
}

class FileAppLogStore implements AppLogStore {
  static const _directoryName = 'time_manager/logs';
  static const _fileName = 'app_logs.jsonl';

  Future<File> _logFile() async {
    final applicationSupport = await getApplicationSupportDirectory();
    final directory = Directory(
      path.join(applicationSupport.path, _directoryName),
    );
    return File(path.join(directory.path, _fileName));
  }

  Future<File> _ensuredLogFile() async {
    final file = await _logFile();
    await file.parent.create(recursive: true);
    return file;
  }

  @override
  Future<List<String>> readLines() async {
    final file = await _logFile();
    if (!await file.exists()) return <String>[];
    return file.readAsLines(encoding: utf8);
  }

  @override
  Future<void> appendLine(String line) async {
    final file = await _ensuredLogFile();
    await file.writeAsString(
      '$line\n',
      mode: FileMode.append,
      encoding: utf8,
      flush: true,
    );
  }

  @override
  Future<void> rewriteLines(List<String> lines) async {
    final file = await _ensuredLogFile();
    final content = lines.isEmpty ? '' : '${lines.join('\n')}\n';
    await file.writeAsString(content, encoding: utf8, flush: true);
  }

  @override
  Future<void> clear() async {
    final file = await _logFile();
    if (await file.exists()) await file.delete();
  }
}
