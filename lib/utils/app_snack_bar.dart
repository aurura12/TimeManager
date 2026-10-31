import 'package:flutter/material.dart';

import '../services/app_identity_service.dart';
import '../services/app_log_service.dart';

/// 统一的 SnackBar 提示入口。
///
/// 默认「顶掉式」：先隐藏当前 SnackBar 再显示新的，避免多条反馈排队堆积。
/// 样式全部来自 [SnackBarThemeData]（见 lib/theme/app_theme.dart），
/// 这里不允许出现任何颜色 / 字号字面量（visual_system_test 守卫）。
void showAppSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 「即时执行 + 可撤销」的统一反馈条。
///
/// 所有破坏性操作（删除类）改为即时执行后，用这个 SnackBar 提供
/// 「撤销」入口。撤销前会校验身份快照，身份已切换则拒绝执行。
void showAppUndoSnackBar(
  BuildContext context, {
  required String message,
  required Future<void> Function() onUndo,
  String actionLabel = '撤销',
  String staleMessage = '身份已切换，撤销已失效',
  String failureMessage = '撤销失败，请重试',
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
              showAppSnackBar(context, staleMessage);
              return;
            }
            _runUndo(context, onUndo, failureMessage);
          },
        ),
      ),
    );
}

Future<void> _runUndo(
  BuildContext context,
  Future<void> Function() onUndo,
  String failureMessage,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
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
    if (messenger != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }
}
