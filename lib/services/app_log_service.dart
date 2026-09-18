import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../models/app_log_entry.dart';
import 'app_log_store.dart';

class AppLogService extends ChangeNotifier {
  static final AppLogService instance = AppLogService();

  static const int defaultMaxEntries = 2000;
  static const int _maxMessageLength = 4096;
  static const int _maxStackTraceLength = 12000;

  AppLogService({
    AppLogStore? store,
    Logger? logger,
    DateTime Function()? clock,
    int maxEntries = defaultMaxEntries,
  })  : _store = store ?? FileAppLogStore(),
        _logger = logger ?? Logger(),
        _clock = clock ?? DateTime.now,
        maxEntries = maxEntries > 0 ? maxEntries : defaultMaxEntries;

  final AppLogStore _store;
  final Logger _logger;
  final DateTime Function() _clock;
  final int maxEntries;
  final List<AppLogEntry> _entries = <AppLogEntry>[];

  bool _initialized = false;
  Future<void>? _initializationFuture;
  Future<void> _writeQueue = Future<void>.value();
  int _storedLineCount = 0;

  List<AppLogEntry> get entries => List<AppLogEntry>.unmodifiable(_entries);

  bool get isInitialized => _initialized;

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final lines = await _store.readLines();
      _storedLineCount = lines.length;
      final loadedEntries = <AppLogEntry>[];
      var needsRewrite = false;

      for (final line in lines) {
        if (line.trim().isEmpty) {
          needsRewrite = true;
          continue;
        }
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map) throw const FormatException('日志不是对象');
          final normalized = _normalizeEntry(
            AppLogEntry.fromJson(Map<String, dynamic>.from(decoded)),
          );
          if (jsonEncode(normalized.toJson()) != line.trim()) {
            needsRewrite = true;
          }
          loadedEntries.add(normalized);
        } catch (error) {
          needsRewrite = true;
          debugPrint('[AppLog] 跳过无效日志: $error');
        }
      }

      final pendingEntries = List<AppLogEntry>.of(_entries);
      _entries
        ..clear()
        ..addAll(
            _sortAndTrim(<AppLogEntry>[...loadedEntries, ...pendingEntries]));
      _initialized = true;

      if (needsRewrite ||
          loadedEntries.length != lines.length ||
          pendingEntries.isNotEmpty ||
          _storedLineCount > _entries.length) {
        await _enqueue(() async {
          await _store.rewriteLines(_chronologicalJsonLines());
          _storedLineCount = _entries.length;
        });
      }
    } catch (error, stackTrace) {
      _initialized = true;
      debugPrint('[AppLog] 初始化日志存储失败: $error\n$stackTrace');
    }

    notifyListeners();
  }

  void log(
    AppLogLevel level,
    String message, {
    String source = 'app',
    Object? error,
    StackTrace? stackTrace,
  }) {
    final entry = _normalizeEntry(
      AppLogEntry(
        timestamp: _clock().toUtc(),
        level: level,
        source: source,
        message: message,
        error: error?.toString(),
        stackTrace: stackTrace?.toString(),
      ),
    );

    _entries.insert(0, entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
    _logToConsole(entry);

    if (!_initialized) return;
    final line = jsonEncode(entry.toJson());
    _enqueue(() async {
      // Do not append the entry that would make the file exceed the limit.
      // Rewriting the already-trimmed in-memory list keeps the on-disk file
      // within the same bound even if the process exits immediately after a
      // log call.
      if (_storedLineCount >= maxEntries) {
        await _store.rewriteLines(_chronologicalJsonLines());
        _storedLineCount = _entries.length;
        return;
      }
      try {
        await _store.appendLine(line);
        _storedLineCount++;
      } catch (_) {
        // The platform may have applied the append before reporting an
        // error. Force a rewrite before the next append to repair either case.
        _storedLineCount = maxEntries;
        rethrow;
      }
    });
  }

  /// 控制台输出，不参与持久化。
  void _logToConsole(AppLogEntry entry) {
    final consoleMessage = entry.error == null
        ? entry.message
        : '${entry.message}: ${entry.error}';
    final safeStackTrace = entry.stackTrace == null
        ? null
        : StackTrace.fromString(entry.stackTrace!);
    switch (entry.level) {
      case AppLogLevel.info:
        _logger.i(consoleMessage);
      case AppLogLevel.warning:
        _logger.w(consoleMessage);
      case AppLogLevel.error:
        _logger.e(consoleMessage, stackTrace: safeStackTrace);
    }
  }

  /// 幂等写入一条带原始发生时间的日志，并返回它**是否已成功落到磁盘**。
  ///
  /// 供原生事件导入使用：只有明确返回 `true` 才可以删除原生队列里的对应事件。
  /// 与 [log] 的区别有两点：
  /// - [log] 走 [_enqueue]，持久化异常被吞掉、只在控制台打印，调用方无法知道结果；
  /// - [log] 用当前时间，本方法保留事件在原生侧的真实发生时间。
  ///
  /// [dedupeKey] 已存在于内存时不会重复插入，而是改为整体重写日志文件：
  /// 这样既能修复「上次追加其实没生效」，也能修复「上次追加已生效但调用报错」，
  /// 两种情况最终都保证磁盘上恰好一条。
  Future<bool> logEventOnceAt(
    AppLogLevel level,
    String message, {
    required String dedupeKey,
    DateTime? timestamp,
    String source = 'app',
    Object? error,
    StackTrace? stackTrace,
  }) {
    final entry = _normalizeEntry(
      AppLogEntry(
        timestamp: (timestamp ?? _clock()).toUtc(),
        level: level,
        source: source,
        message: message,
        error: error?.toString(),
        stackTrace: stackTrace?.toString(),
        dedupeKey: dedupeKey,
      ),
    );

    final alreadyPresent = _entries.any((e) => e.dedupeKey == dedupeKey);
    if (!alreadyPresent) {
      _entries.insert(0, entry);
      if (_entries.length > maxEntries) {
        _entries.removeRange(maxEntries, _entries.length);
      }
      notifyListeners();
      _logToConsole(entry);
    }

    if (!_initialized) return Future<bool>.value(false);
    return _persistReporting(entry, rewriteOnly: alreadyPresent);
  }

  /// 与 [log] 的持久化路径相同，但把成功与否回报给调用方。
  Future<bool> _persistReporting(
    AppLogEntry entry, {
    required bool rewriteOnly,
  }) {
    final completer = Completer<bool>();
    _writeQueue = _writeQueue.then<void>((_) async {
      try {
        if (rewriteOnly || _storedLineCount >= maxEntries) {
          await _store.rewriteLines(_chronologicalJsonLines());
          _storedLineCount = _entries.length;
        } else {
          await _store.appendLine(jsonEncode(entry.toJson()));
          _storedLineCount++;
        }
        completer.complete(true);
      } catch (error, stackTrace) {
        // 与 _enqueue 保持一致：追加可能已经生效但报错，下次强制重写修复。
        _storedLineCount = maxEntries;
        debugPrint('[AppLog] 原生事件持久化失败: $error\n$stackTrace');
        completer.complete(false);
      }
    });
    return completer.future;
  }

  void info(
    String message, {
    String source = 'app',
    Object? error,
    StackTrace? stackTrace,
  }) {
    log(
      AppLogLevel.info,
      message,
      source: source,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void warning(
    String message, {
    String source = 'app',
    Object? error,
    StackTrace? stackTrace,
  }) {
    log(
      AppLogLevel.warning,
      message,
      source: source,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void error(
    String message, {
    String source = 'app',
    Object? error,
    StackTrace? stackTrace,
  }) {
    log(
      AppLogLevel.error,
      message,
      source: source,
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<void> clear() async {
    _entries.clear();
    _storedLineCount = 0;
    notifyListeners();
    await _enqueue(() async {
      await _store.clear();
      _storedLineCount = 0;
    });
  }

  Future<void> flush() => _writeQueue;

  Future<void> _enqueue(Future<void> Function() operation) {
    _writeQueue = _writeQueue.then<void>((_) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        debugPrint('[AppLog] 持久化失败: $error\n$stackTrace');
      }
    });
    return _writeQueue;
  }

  List<AppLogEntry> _sortAndTrim(Iterable<AppLogEntry> source) {
    final result = List<AppLogEntry>.of(source)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (result.length > maxEntries) {
      result.removeRange(maxEntries, result.length);
    }
    return result;
  }

  List<String> _chronologicalJsonLines() {
    return _entries.reversed
        .map((entry) => jsonEncode(entry.toJson()))
        .toList(growable: false);
  }

  AppLogEntry _normalizeEntry(AppLogEntry entry) {
    return AppLogEntry(
      timestamp: entry.timestamp.toUtc(),
      level: entry.level,
      source: _truncate(_sanitize(entry.source.trim()), 120),
      message: _truncate(_sanitize(entry.message), _maxMessageLength),
      error: _normalizeOptional(entry.error, _maxMessageLength),
      stackTrace: _normalizeOptional(entry.stackTrace, _maxStackTraceLength),
      dedupeKey: entry.dedupeKey,
    );
  }

  String? _normalizeOptional(String? value, int maxLength) {
    if (value == null || value.isEmpty) return null;
    return _truncate(_sanitize(value), maxLength);
  }

  static final RegExp _sensitiveValuePattern = RegExp(
    r'''\b(token|access[_-]?token|refresh[_-]?token|id[_-]?token|authorization|password|passcode|api[_-]?key|client[_-]?secret|secret|cookie|credential)s?\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\r\n,;]+)''',
    caseSensitive: false,
  );

  static final RegExp _bearerPattern = RegExp(
    r'\bBearer\s+[^\s,;]+',
    caseSensitive: false,
  );

  String _sanitize(String value) {
    final sanitized = value.replaceAllMapped(
      _sensitiveValuePattern,
      (match) => '${match.group(1)}=[REDACTED]',
    );
    return sanitized.replaceAllMapped(
      _bearerPattern,
      (_) => 'Bearer [REDACTED]',
    );
  }

  String _truncate(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    const suffix = '\n...[已截断]';
    if (maxLength <= suffix.length) return value.substring(0, maxLength);
    return '${value.substring(0, maxLength - suffix.length)}$suffix';
  }
}
