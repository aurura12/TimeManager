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
  static const maxBytes = 2 * 1024 * 1024;
  static const retention = Duration(days: 30);

  FileAppLogStore({
    Future<Directory> Function()? applicationSupportDirectory,
    DateTime Function()? clock,
  })  : _applicationSupportDirectory =
            applicationSupportDirectory ?? getApplicationSupportDirectory,
        _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _applicationSupportDirectory;
  final DateTime Function() _clock;
  List<String>? _cachedLines;

  Future<File> _logFile() async {
    final applicationSupport = await _applicationSupportDirectory();
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
    final rawLines = await _loadRawLines(file);
    final lines = _prepareLines(rawLines, now: _clock());
    if (!_sameLines(rawLines, lines)) {
      await _writeLines(file, lines);
    }
    _cachedLines = lines;
    return List<String>.of(lines);
  }

  @override
  Future<void> appendLine(String line) async {
    final file = await _logFile();
    final rawLines = await _loadRawLines(file);
    final lines = _prepareLines(<String>[...rawLines, line], now: _clock());

    final canAppend = lines.length == rawLines.length + 1 &&
        lines.last == line &&
        _sameLines(lines.sublist(0, lines.length - 1), rawLines) &&
        _byteLength(lines) <= maxBytes;
    if (canAppend) {
      final ensuredFile = await _ensuredLogFile();
      await ensuredFile.writeAsString(
        '$line\n',
        mode: FileMode.append,
        encoding: utf8,
        flush: true,
      );
    } else {
      await _writeLines(file, lines);
    }
    _cachedLines = lines;
  }

  @override
  Future<void> rewriteLines(List<String> lines) async {
    final file = await _logFile();
    final prepared = _prepareLines(lines, now: _clock());
    await _writeLines(file, prepared);
    _cachedLines = prepared;
  }

  @override
  Future<void> clear() async {
    final file = await _logFile();
    if (await file.exists()) await file.delete();
    _cachedLines = <String>[];
  }

  Future<List<String>> _loadRawLines(File file) async {
    final cached = _cachedLines;
    if (cached != null) return List<String>.of(cached);
    if (!await file.exists()) return <String>[];
    return file.readAsLines(encoding: utf8);
  }

  Future<void> _writeLines(File file, List<String> lines) async {
    await file.parent.create(recursive: true);
    final content = lines.isEmpty ? '' : '${lines.join('\n')}\n';
    await file.writeAsString(content, encoding: utf8, flush: true);
  }

  List<String> _prepareLines(
    Iterable<String> lines, {
    required DateTime now,
  }) {
    final cutoff = now.toUtc().subtract(retention);
    final retained = <String>[];
    for (final line in lines) {
      final timestamp = _timestampOf(line);
      if (timestamp != null && timestamp.isBefore(cutoff)) continue;
      retained.add(line);
    }

    var bytes = 0;
    final newestFirst = <String>[];
    for (var i = retained.length - 1; i >= 0; i--) {
      final line = retained[i];
      final lineBytes = utf8.encode('$line\n').length;
      if (lineBytes > maxBytes) continue;
      if (bytes + lineBytes > maxBytes) break;
      newestFirst.add(line);
      bytes += lineBytes;
    }
    return newestFirst.reversed.toList(growable: false);
  }

  DateTime? _timestampOf(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      final value = decoded['timestamp'];
      return value is String ? DateTime.tryParse(value)?.toUtc() : null;
    } catch (_) {
      // Invalid lines are left for AppLogService's existing parser to remove.
      return null;
    }
  }

  int _byteLength(Iterable<String> lines) {
    return lines.fold<int>(
        0, (sum, line) => sum + utf8.encode('$line\n').length);
  }

  bool _sameLines(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
