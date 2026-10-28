import 'package:flutter/widgets.dart';

/// 哪些生命周期状态算「进入后台」，需要停掉前台轮询并立即落盘。
///
/// 桌面端最小化窗口走的是 [AppLifecycleState.hidden]（不是 `paused`），
/// 漏掉它会让 Windows 最小化后定时器继续唤醒、未落盘的草稿继续等防抖。
bool isAppBackgroundedLifecycleState(AppLifecycleState state) {
  return state == AppLifecycleState.paused ||
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.detached;
}
