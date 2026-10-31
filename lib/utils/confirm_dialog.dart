import 'package:flutter/material.dart';

/// 统一的确认对话框。
///
/// 返回 true 表示用户确认。[destructive] 为 true 时确认按钮使用
/// error 配色实心样式（与既有删除确认一致），颜色取自 [ColorScheme]，
/// 不允许出现颜色字面量（visual_system_test 守卫）。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  String cancelLabel = '取消',
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final colorScheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: colorScheme.error,
                    foregroundColor: colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}
