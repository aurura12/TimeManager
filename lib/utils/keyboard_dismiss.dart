import 'package:flutter/widgets.dart';

/// 「点输入框以外的区域收起键盘」的统一入口。
///
/// 手机上必须显式挂上：`TextField.onTapOutside` 为空时会走框架默认的
/// `_EditableTextTapOutsideAction`，它对 Android / iOS 的触摸事件**刻意不
/// 失焦**（只对鼠标、触控笔和桌面平台 unfocus），所以点空白收键盘不会
/// 自动生效，只能靠系统返回键。
///
/// 用法：`TextField(onTapOutside: dismissKeyboardOnTapOutside, ...)`。
/// 桌面端挂上也无害——框架本来就会失焦。
void dismissKeyboardOnTapOutside(PointerDownEvent event) {
  FocusManager.instance.primaryFocus?.unfocus();
}
