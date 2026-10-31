import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../providers/haptics_provider.dart';

/// 触感强度。刷格 / 拖边界这类连续动作只用 [selection]，
/// 一次性成功（删除、提交、打卡）才用 [light] / [medium]。
enum HapticStrength { selection, light, medium }

/// 触感反馈的唯一入口。
///
/// 读本机开关（`我的 → 操作与布局 → 触感反馈`），关闭时直接返回；
/// 没有注册 Provider 的宿主（部分测试）按默认开启处理。
///
/// 桌面端及部分平台没有实现 `HapticFeedback` 通道，调用会抛
/// `MissingPluginException`。这里必须吞掉异常：触感是锦上添花，
/// 绝不能中断手势链路，也不能把错误灌进运行日志。
void playHaptic(BuildContext context, HapticStrength strength) {
  final enabled = context.read<HapticsProvider?>()?.enabled ?? true;
  if (!enabled) return;
  unawaited(_dispatch(strength).catchError((Object _) {}));
}

Future<void> _dispatch(HapticStrength strength) {
  switch (strength) {
    case HapticStrength.selection:
      return HapticFeedback.selectionClick();
    case HapticStrength.light:
      return HapticFeedback.lightImpact();
    case HapticStrength.medium:
      return HapticFeedback.mediumImpact();
  }
}
