import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const Duration _defaultTimeout = Duration(seconds: 15);
const int _maxRetries = 2;

/// Remote Contents API safety limits.
///
/// These limits apply to one API operation. They are deliberately kept in the
/// shared layer so diary indexing and any other caller of a Contents API do
/// not accidentally choose different network bounds.
class ContentsApiLimits {
  static const defaults = ContentsApiLimits(
    maxResponseBytes: 4 * 1024 * 1024,
    maxFileBytes: 2 * 1024 * 1024,
    maxTreeEntries: 20000,
    maxDirectoryEntries: 10000,
    maxRequestsPerOperation: 256,
    maxConcurrentRequests: 4,
    maxTreeDepth: 32,
    pageSize: 100,
    maxPages: 100,
  );

  final int maxResponseBytes;
  final int maxFileBytes;
  final int maxTreeEntries;
  final int maxDirectoryEntries;
  final int maxRequestsPerOperation;
  final int maxConcurrentRequests;
  final int maxTreeDepth;
  final int pageSize;
  final int maxPages;

  const ContentsApiLimits({
    required this.maxResponseBytes,
    required this.maxFileBytes,
    required this.maxTreeEntries,
    required this.maxDirectoryEntries,
    required this.maxRequestsPerOperation,
    required this.maxConcurrentRequests,
    required this.maxTreeDepth,
    required this.pageSize,
    required this.maxPages,
  })  : assert(maxResponseBytes > 0),
        assert(maxFileBytes > 0),
        assert(maxTreeEntries > 0),
        assert(maxDirectoryEntries > 0),
        assert(maxRequestsPerOperation > 0),
        assert(maxConcurrentRequests > 0),
        assert(maxTreeDepth > 0),
        assert(pageSize > 0),
        assert(maxPages > 0);
}

class ContentsTreeEntry {
  final String type;
  final String path;
  final String sha;
  final int? size;

  const ContentsTreeEntry({
    required this.type,
    required this.path,
    required this.sha,
    this.size,
  });
}

class ContentsTreeResult {
  final bool success;
  final List<ContentsTreeEntry> entries;
  final bool truncated;
  final String? error;

  const ContentsTreeResult._({
    required this.success,
    required this.entries,
    required this.truncated,
    this.error,
  });

  factory ContentsTreeResult.success(List<ContentsTreeEntry> entries) {
    return ContentsTreeResult._(
      success: true,
      entries: List.unmodifiable(entries),
      truncated: false,
    );
  }

  factory ContentsTreeResult.error(
    String message, {
    bool truncated = false,
  }) {
    return ContentsTreeResult._(
      success: false,
      entries: const [],
      truncated: truncated,
      error: message,
    );
  }
}

class ContentsDirectoryResult {
  final bool success;
  final List<ContentsTreeEntry> entries;
  final bool truncated;
  final String? error;

  const ContentsDirectoryResult._({
    required this.success,
    required this.entries,
    required this.truncated,
    this.error,
  });

  factory ContentsDirectoryResult.success(List<ContentsTreeEntry> entries) {
    return ContentsDirectoryResult._(
      success: true,
      entries: List.unmodifiable(entries),
      truncated: false,
    );
  }

  factory ContentsDirectoryResult.error(
    String message, {
    bool truncated = false,
  }) {
    return ContentsDirectoryResult._(
      success: false,
      entries: const [],
      truncated: truncated,
      error: message,
    );
  }
}

class ContentsResponseTooLargeException implements Exception {
  final int maxBytes;

  const ContentsResponseTooLargeException(this.maxBytes);

  @override
  String toString() => '远端响应超过 $maxBytes 字节上限';
}

class ContentsRequestBudget {
  final int maxRequests;
  int _used = 0;

  ContentsRequestBudget(this.maxRequests);

  bool take() {
    if (_used >= maxRequests) return false;
    _used++;
    return true;
  }
}

class _AsyncRequestLimiter {
  final int maxConcurrent;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  _AsyncRequestLimiter(this.maxConcurrent);

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.addLast(waiter);
    return waiter.future;
  }

  void _release() {
    final waiter = _waiters.isEmpty ? null : _waiters.removeFirst();
    if (waiter != null) {
      waiter.complete();
    } else {
      _active--;
    }
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    await _acquire();
    try {
      return await operation();
    } finally {
      _release();
    }
  }
}

final Expando<_AsyncRequestLimiter> _requestLimiters =
    Expando<_AsyncRequestLimiter>();

Future<T> runWithContentsRequestLimit<T>(
  Object owner, {
  required int maxConcurrent,
  required Future<T> Function() operation,
}) {
  final existing = _requestLimiters[owner];
  final limiter = existing ?? _AsyncRequestLimiter(maxConcurrent);
  if (existing == null) _requestLimiters[owner] = limiter;
  return limiter.run(operation);
}

Future<http.Response> sendLimitedContentsRequest({
  required Object owner,
  required http.Client? client,
  required http.BaseRequest request,
  required ContentsApiLimits limits,
}) {
  return runWithContentsRequestLimit(
    owner,
    maxConcurrent: limits.maxConcurrentRequests,
    operation: () async {
      final ownedClient = client == null ? http.Client() : null;
      final requestClient = client ?? ownedClient!;
      try {
        final streamed = await requestClient.send(request);
        return await readLimitedContentsResponse(
          streamed,
          maxBytes: limits.maxResponseBytes,
        );
      } finally {
        ownedClient?.close();
      }
    },
  );
}

Future<http.Response> readLimitedContentsResponse(
  http.StreamedResponse response, {
  required int maxBytes,
}) async {
  final contentLength = response.contentLength;
  if (contentLength != null && contentLength > maxBytes) {
    await response.stream.listen((_) {}).cancel();
    throw ContentsResponseTooLargeException(maxBytes);
  }

  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in response.stream) {
    total += chunk.length;
    if (total > maxBytes) {
      // Breaking an await-for cancels the stream subscription, so the
      // remaining response is not buffered after the limit is reached.
      break;
    }
    builder.add(chunk);
  }
  if (total > maxBytes) {
    throw ContentsResponseTooLargeException(maxBytes);
  }

  final bodyBytes = builder.takeBytes();
  return http.Response.bytes(
    bodyBytes,
    response.statusCode,
    headers: response.headers,
    request: response.request,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}

bool _isRetryableError(Object e) {
  return e is TimeoutException ||
      e is SocketException ||
      e is HttpException ||
      e is IOException ||
      e is HandshakeException ||
      e is TlsException;
}

Future<T> requestWithRetry<T>(
  Future<T> Function() request, {
  int maxRetries = _maxRetries,
  Duration timeout = _defaultTimeout,
}) async {
  for (int i = 0; i <= maxRetries; i++) {
    try {
      return await request().timeout(timeout);
    } catch (e) {
      if (i == maxRetries || !_isRetryableError(e)) rethrow;
      await Future.delayed(const Duration(seconds: 1));
    }
  }
  throw StateError('unreachable');
}

String normalizeBase64(String value) {
  return value.replaceAll('\n', '');
}

String extractErrorMessage(http.Response response) {
  try {
    final decoded = json.decode(response.body);
    if (decoded is Map<String, dynamic>) {
      final message = decoded['message']?.toString();
      if (message != null && message.isNotEmpty) return message;
      final messages = decoded['messages'];
      if (messages is List && messages.isNotEmpty) {
        return messages.join('; ');
      }
    }
  } catch (_) {}
  return '请求失败（${response.statusCode}）';
}
