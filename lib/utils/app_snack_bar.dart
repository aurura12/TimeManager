import 'package:flutter/material.dart';

import '../services/app_identity_service.dart';
import '../services/app_log_service.dart';

/// 「撤销」提示条的展示时长：撤销窗口也以它为准。
const Duration appUndoSnackBarDuration = Duration(seconds: 6);

/// 当前挂着撤销提示条的 messenger。
///
/// 撤销条在展示期间不允许被普通提示顶掉（用户刚删完东西，正要伸手点
/// 「撤销」），普通提示先记到 [_pendingMessage]，等撤销窗口结束后再补发。
/// 用 messenger 本身做键而不是全局布尔：多个宿主（测试里的每个
/// MaterialApp、未来可能的嵌套 navigator）互不干扰。
ScaffoldMessengerState? _undoMessenger;
int _undoGeneration = 0;
({String message, Duration? duration})? _pendingMessage;

/// 统一的普通提示入口。
///
/// 默认「顶掉式」：先隐藏当前提示条再显示新的，避免多条反馈排队堆积。
/// [duration] 为 null 时沿用 SnackBar 的框架默认时长。
/// [interruptUndo] 为 true 时允许立刻顶掉正在展示的「撤销」提示条——只给
/// 「用户刚点了按钮、必须马上看到结果」的失败提示用。
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
  bool interruptUndo = false,
}) {
  showAppSnackBarOn(
    ScaffoldMessenger.maybeOf(context),
    message,
    duration: duration,
    interruptUndo: interruptUndo,
  );
}

/// 作用在已抓取的 [ScaffoldMessengerState] 上的普通提示。
///
/// [messenger] 为 null（宿主没有 ScaffoldMessenger，或页面已经销毁）时
/// 静默返回，不抛异常——异步回调里 ScaffoldMessenger.maybeOf 拿到的就是
/// 可空值。
void showAppSnackBarOn(
  ScaffoldMessengerState? messenger,
  String message, {
  Duration? duration,
  bool interruptUndo = false,
}) {
  if (messenger == null || !messenger.mounted) return;
  if (!interruptUndo && _isUndoWindowOpenOn(messenger)) {
    // 撤销窗口里只留最新一条：后到的覆盖先到的，避免排队积累。
    _pendingMessage = (message: message, duration: duration);
    return;
  }
  _showNow(messenger, message, duration);
}

/// 清掉当前提示条，以及撤销窗口里还没展示的待发消息。
///
/// 切换身份时必须调用：挂着的撤销条属于旧身份，点下去注定失效。
void clearAppSnackBars(ScaffoldMessengerState? messenger) {
  _undoGeneration++;
  _undoMessenger = null;
  _pendingMessage = null;
  if (messenger == null || !messenger.mounted) return;
  messenger.clearSnackBars();
}

/// 「即时执行 + 可撤销」的统一反馈条。
///
/// 所有破坏性操作（删除类）改为即时执行后，用这个 SnackBar 提供
/// 「撤销」入口。撤销前会校验身份快照，身份已切换则拒绝执行。
///
/// 展示时就把 [ScaffoldMessenger] 抓下来，之后按钮回调只用它、不再碰
/// 调用方的 context：SnackBar 挂在 ScaffoldMessenger 上会跨路由存活，
/// 页面 pop 之后原 context 已 deactivate，再通过它查祖先会抛
/// 「Looking up a deactivated widget's ancestor is unsafe」，
/// 撤销回调根本执行不到（删除目标后详情页自动关闭就是这条路径）。
void showAppUndoSnackBar(
  BuildContext context, {
  required String message,
  required Future<void> Function() onUndo,
  String actionLabel = '撤销',
  String staleMessage = '身份已切换，撤销已失效',
  String failureMessage = '撤销失败',
  String? identityToken,
  Duration duration = appUndoSnackBarDuration,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final generation = ++_undoGeneration;
  _undoMessenger = messenger;
  // 新的撤销条作废旧排队：上一条撤销窗口的待发消息已经没有意义了。
  _pendingMessage = null;
  messenger.hideCurrentSnackBar();
  final controller = messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      // Flutter 3.47 起 persist 默认跟随 action：带按钮的提示条会永远挂着、
      // duration 形同失效。这里显式关掉，让「撤销窗口」真的只有 6 秒，
      // 否则排队中的普通提示会一直等不到结束。
      persist: false,
      action: SnackBarAction(
        label: actionLabel,
        onPressed: () {
          if (identityToken != null &&
              AppIdentityService.identityStamp != identityToken) {
            _showNow(messenger, staleMessage, null);
            return;
          }
          _runUndo(messenger, onUndo, failureMessage);
        },
      ),
    ),
  );
  // 超时、点动作、hideCurrentSnackBar、clearSnackBars、宿主销毁都会完成
  // closed，撤销窗口因此只用一条回调收尾，不需要自建定时器。
  controller.closed.whenComplete(() => _finishUndoWindow(generation));
}

bool _isUndoWindowOpenOn(ScaffoldMessengerState messenger) {
  final undo = _undoMessenger;
  if (undo == null || !identical(undo, messenger)) return false;
  if (!undo.mounted) {
    _undoMessenger = null;
    _pendingMessage = null;
    return false;
  }
  return true;
}

void _finishUndoWindow(int generation) {
  if (generation != _undoGeneration) return;
  final messenger = _undoMessenger;
  final pending = _pendingMessage;
  _undoMessenger = null;
  _pendingMessage = null;
  if (messenger == null || pending == null) return;
  _showNow(messenger, pending.message, pending.duration);
}

void _showNow(
  ScaffoldMessengerState messenger,
  String message,
  Duration? duration,
) {
  if (!messenger.mounted) return;
  // 立刻展示的提示意味着撤销窗口已经结束（或被主动顶掉），顺手清干净，
  // 否则下一条普通提示会被记成「待发」而永远等不到 flush。
  _pendingMessage = null;
  if (identical(_undoMessenger, messenger)) _undoMessenger = null;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      duration == null
          ? SnackBar(content: Text(message))
          : SnackBar(content: Text(message), duration: duration),
    );
}

Future<void> _runUndo(
  ScaffoldMessengerState messenger,
  Future<void> Function() onUndo,
  String failureMessage,
) async {
  try {
    await onUndo();
  } catch (error, stackTrace) {
    try {
      AppLogService.instance.error(
        '撤销操作失败',
        source: 'undo',
        error: error,
        stackTrace: stackTrace,
      );
    } catch (_) {
      // 日志服务不可用时忽略，用户提示不受影响。
    }
    _showNow(messenger, failureMessage, null);
  }
}
