import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const Duration _defaultTimeout = Duration(seconds: 15);
const int _maxRetries = 2;

bool _isRetryableError(Object e) {
  return e is TimeoutException ||
      e is SocketException ||
      e is HttpException ||
      e is IOException ||
      e is HandshakeException ||
      e is TlsException;
}

Future<http.Response> requestWithRetry(
  Future<http.Response> Function() request, {
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
