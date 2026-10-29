import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// 单个字符串偏好键的串行读写；失败时恢复 SharedPreferences 的进程内缓存。
class TransactionalPreferenceString {
  TransactionalPreferenceString(this.key);

  final String key;
  Future<void>? _operationTail;

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    final previous = _operationTail;
    final done = Completer<void>();
    final tail = done.future;
    _operationTail = tail;
    try {
      if (previous != null) await previous;
      return await operation();
    } finally {
      done.complete();
      if (identical(_operationTail, tail)) _operationTail = null;
    }
  }

  Future<String?> load() => _serialized(() async {
        final prefs = await SharedPreferences.getInstance();
        return prefs.getString(key);
      });

  Future<bool> save(String value) => _serialized(() async {
        SharedPreferences prefs;
        String? previous;
        try {
          prefs = await SharedPreferences.getInstance();
          previous = prefs.getString(key);
        } catch (_) {
          return false;
        }
        try {
          if (await prefs.setString(key, value)) return true;
        } catch (_) {
          // 平台通道异常与写入返回 false 一样按失败处理。
        }

        // SharedPreferences 在写盘前就改了进程内缓存；即使恢复写盘也失败，
        // setString/remove 仍会先把此键的缓存恢复，不影响其他偏好键。
        try {
          if (previous == null) {
            await prefs.remove(key);
          } else {
            await prefs.setString(key, previous);
          }
        } catch (_) {
          // 缓存已恢复；原始写入依然向调用方报告失败。
        }
        return false;
      });

  Future<void> remove() => _serialized(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(key);
      });
}
