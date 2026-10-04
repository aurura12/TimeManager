import 'dart:io';

import 'package:flutter/widgets.dart';

/// 平板宽屏判定：仅 iOS/iPadOS 且宽度 >= 600 时启用平板布局。
///
/// iOS 分屏窄栏时自动退回底部导航；桌面导航由独立的布局偏好决定。
bool isWideTablet(BuildContext context) {
  if (!Platform.isIOS) return false;
  return MediaQuery.sizeOf(context).width >= 600;
}
