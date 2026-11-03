import 'package:flutter/widgets.dart';

import '../theme/app_tokens.dart';

/// 把系统「减弱动态效果」统一折算成零时长。
///
/// 页面与组件不要自己判断 `MediaQuery.disableAnimationsOf`：漏一处就会留下
/// 一个关不掉的动画，统一从这里取。
Duration appMotionDuration(
  BuildContext context, [
  Duration base = AppMotion.transition,
]) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : base;
