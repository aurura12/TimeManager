import 'package:material_ui/material_ui.dart';

/// 临时兼容层：给仍在读旧 package:flutter/material.dart 的第三方组件提供
/// 旧版 [Theme] 与 MaterialLocalizations。
///
/// 目前唯一的调用点是 home_screen.dart 里 reorderables 的 ReorderableWrap——
/// 它在构建每个子项时直接调 MaterialLocalizations.of(context)（旧库类型带
/// 断言和强解包），在 material_ui 的 MaterialApp 下会断言失败 / 空指针。
///
/// 内部包的是官方迁移工具 MaterialUiCompatibilityBridge，它自身带
/// @Deprecated，因此这里统一 ignore 一次；否则每个调用点都会多一条
/// deprecated_member_use，flutter analyze 无法保持 0 issue。
///
/// 退出条件：reorderables 发布基于 material_ui 的版本后，删掉本文件与
/// home_screen.dart 里唯一的那处包裹。
class LegacyMaterialBridge extends StatelessWidget {
  const LegacyMaterialBridge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // ignore: deprecated_member_use
    return MaterialUiCompatibilityBridge(child: child);
  }
}

/// reorderables 默认的拖拽反馈会用旧 material 的 Material + Card 把被拖动的
/// 子项重新包一层，而子项里 material_ui 的 InkWell 只认同一套库的 Material，
/// 拖动时会报「No Material widget found」。这里用同结构的 material_ui 版本替换。
Widget materialUiDraggableFeedback(
  BuildContext context,
  BoxConstraints constraints,
  Widget child,
) {
  return Transform(
    transform: Matrix4.rotationZ(0),
    alignment: Alignment.topLeft,
    child: Material(
      elevation: 6,
      color: Colors.transparent,
      borderRadius: BorderRadius.zero,
      child: Card(
        child: ConstrainedBox(constraints: constraints, child: child),
      ),
    ),
  );
}
