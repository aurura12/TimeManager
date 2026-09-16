import 'dart:async';

import '../models/sync_center_state.dart';

/// 已接入模块的跨页面、跨服务同步互斥锁。
///
/// 同一个模块可能同时由页面自动同步、同步中心和应用恢复流程触发。
/// 目前日记、出行和打卡通过这里串行化；日程、分类和目标由 TimeProvider
/// 内部的同步状态负责。这里按模块维护一条全局 Future 队列，保证接入模块
/// 一次只有一个远端读改写流程在执行。
class SyncOperationLock {
  SyncOperationLock._();

  static final SyncOperationLock instance = SyncOperationLock._();

  final Map<SyncModule, Future<void>> _tails = {};

  Future<T> run<T>(SyncModule module, Future<T> Function() action) async {
    final previous = _tails[module];
    final done = Completer<void>();
    _tails[module] = done.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      done.complete();
      if (identical(_tails[module], done.future)) {
        _tails.remove(module);
      }
    }
  }
}
