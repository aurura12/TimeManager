import 'dart:io';

import 'package:flutter/widgets.dart';

/// 平板宽屏判定：仅 iOS/iPadOS 且宽度 >= 600 时启用平板布局。
///
/// 安卓/Win 保持原有手机式布局不变；iOS 分屏窄栏时自动退回手机布局。
bool isWideTablet(BuildContext context) {
  if (!Platform.isIOS) return false;
  return MediaQuery.sizeOf(context).width >= 600;
}
