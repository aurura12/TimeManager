import 'package:flutter/material.dart';

/// 事件名文本：按本机偏好渲染一行或两行，放不下时可查看完整名称。
///
/// 查看完整名称的手势按平台分开：
/// - 手机 / 平板：长按弹出气泡（[TooltipTriggerMode.longPress]）
/// - 桌面：鼠标悬停弹出气泡（[Tooltip] 自身的 MouseRegion，与 triggerMode 无关）
///
/// 只有真的被省略号截断时才挂 [Tooltip]；名字能完整放下时不加任何手势，
/// 避免网格和事件栏里到处乱弹提示。
class EventLabelText extends StatelessWidget {
  const EventLabelText({
    super.key,
    required this.text,
    required this.style,
    required this.maxLines,
    this.textAlign = TextAlign.center,
    this.detail,
    this.enableTooltip = true,
  });

  final String text;
  final TextStyle style;
  final int maxLines;
  final TextAlign textAlign;

  /// 气泡第二行，例如「09:10–09:30 · 学习」；为 null 时只显示完整名称。
  final String? detail;

  /// 刷子模式下整列由外层 Listener 接管指针，长按要关掉，避免抢手势。
  final bool enableTooltip;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: maxLines,
      textAlign: textAlign,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (!enableTooltip || text.isEmpty) return label;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (!maxWidth.isFinite || maxWidth <= 0) return label;
        final scaler = MediaQuery.textScalerOf(context);
        // 先按"一个汉字占一个字号宽"粗判：明显放得下就不必测量。
        // 拖选时网格会整片重建，这里省掉的是每帧上百次 TextPainter 布局。
        final scaledFontSize = scaler.scale(style.fontSize ?? 14);
        final approxCharsPerLine = (maxWidth / scaledFontSize).floor();
        if (text.runes.length <= (approxCharsPerLine - 1).clamp(1, 999) *
            maxLines) {
          return label;
        }
        // 可能放不下时，用与 Text 相同的约束和缩放量精确量一遍，
        // 只有真的被省略号截断才提供提示。
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout(maxWidth: maxWidth);
        final truncated = painter.didExceedMaxLines;
        painter.dispose();
        if (!truncated) return label;

        return Tooltip(
          message: detail == null ? text : '$text\n$detail',
          // 手机长按、桌面悬停各自生效，不需要额外判断平台。
          triggerMode: TooltipTriggerMode.longPress,
          // 悬停要停留一下才弹，避免鼠标划过时满屏气泡；长按不受影响。
          waitDuration: const Duration(milliseconds: 200),
          showDuration: const Duration(seconds: 4),
          constraints: const BoxConstraints(maxWidth: 240),
          child: label,
        );
      },
    );
  }
}
