import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/screens/main_screen.dart';

void main() {
  test('桌面最小化（hidden）也算进入后台，必须停掉前台轮询', () {
    // Windows/macOS 最小化窗口走的是 hidden，不是 paused；
    // 漏掉它会让最小化后 60 秒定时器继续唤醒。
    expect(isAppBackgroundedLifecycleState(AppLifecycleState.hidden), isTrue);
    expect(isAppBackgroundedLifecycleState(AppLifecycleState.paused), isTrue);
    expect(isAppBackgroundedLifecycleState(AppLifecycleState.detached), isTrue);
  });

  test('前台状态不算进入后台', () {
    expect(isAppBackgroundedLifecycleState(AppLifecycleState.resumed), isFalse);
    // inactive 只是失焦，窗口仍然可见，继续轮询才符合"无感同步"。
    expect(isAppBackgroundedLifecycleState(AppLifecycleState.inactive), isFalse);
  });
}
