import 'package:flutter/material.dart';

import '../services/app_identity_service.dart';
import '../services/app_log_service.dart';

/// 统一的 SnackBar 提示入口。
///
/// 默认「顶掉式」：先隐藏当前 SnackBar 再显示新的，避免多条反馈排队堆积。
/// 样式全部来自 [SnackBarThemeData]（见 lib/theme/app_theme.dart），
/// 这里不允许出现任何颜色 / 字号字面量（visual_system_test 守卫）。
void showAppSnackBar(BuildContext context, String message) {
  _showMessage(ScaffoldMessenger.of(context), message);
}

/// 「即时执行 + 可撤销」的统一反馈条。
///
/// 所有破坏性操作（删除类）改为即时执行后，用这个 SnackBar 提供
/// 「撤销」入口。撤销前会校验身份快照，身份已切换则拒绝执行。
///
/// 展示时就把 [ScaffoldMessenger] 抓下来，之后按钮回调只用它、不再碰
/// 调用方的 context：SnackBar 挂在 ScaffoldMessenger 上会跨路由存活，
/// 页面 pop 之后原 context 已 deactivate，再 `ScaffoldMessenger.of(context)`
/// 会抛「Looking up a deactivated widget's ancestor is unsafe」，
/// 撤销回调根本执行不到（删除目标后详情页自动关闭就是这条路径）。
void showAppUndoSnackBar(
  BuildContext context, {
  required String message,
  required Future<void> Function() onUndo,
  String actionLabel = '撤销',
  String staleMessage = '身份已切换，撤销已失效',
  String failureMessage = '撤销失败',
  String? identityToken,
  Duration duration = const Duration(seconds: 6),
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        action: SnackBarAction(
          label: actionLabel,
          onPressed: () {
            if (identityToken != null &&
                AppIdentityService.identityStamp != identityToken) {
              _showMessage(messenger, staleMessage);
              return;
            }
            _runUndo(messenger, onUndo, failureMessage);
          },
        ),
      ),
    );
}

void _showMessage(ScaffoldMessengerState messenger, String message) {
  if (!messenger.mounted) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
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
    _showMessage(messenger, failureMessage);
  }
}
