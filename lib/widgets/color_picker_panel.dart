import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 不带透明度的 HSV 取色器，支持触控、鼠标及方向键。
class ColorPickerPanel extends StatefulWidget {
  const ColorPickerPanel({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<Color>? onChanged;

  @override
  State<ColorPickerPanel> createState() => _ColorPickerPanelState();
}

class _ColorPickerPanelState extends State<ColorPickerPanel> {
  late HSVColor _color;
  final FocusNode _planeFocus = FocusNode();
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  @override
  void initState() {
    super.initState();
    _color = HSVColor.fromColor(AppSemanticColors.opaque(widget.color));
  }

  @override
  void didUpdateWidget(covariant ColorPickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = AppSemanticColors.opaque(widget.color);
    // 灰色和黑色不携带色相；保留刚刚选择的 HSV，避免拖动时跳回红色。
    if (incoming != _color.toColor()) _color = HSVColor.fromColor(incoming);
  }

  @override
  void dispose() {
    _planeFocus.dispose();
    super.dispose();
  }

  void _change(HSVColor color) {
    if (!_enabled) return;
    setState(() => _color = color);
    widget.onChanged!(color.toColor());
  }

  void _pickPosition(Offset position, Size size) {
    if (!_enabled || size.isEmpty) return;
    _planeFocus.requestFocus();
    _change(_color
        .withSaturation((position.dx / size.width).clamp(0.0, 1.0))
        .withValue((1 - position.dy / size.height).clamp(0.0, 1.0)));
  }

  void _adjust({double saturation = 0, double value = 0}) {
    _change(_color
        .withSaturation((_color.saturation + saturation).clamp(0.0, 1.0))
        .withValue((_color.value + value).clamp(0.0, 1.0)));
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!_enabled || event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _adjust(saturation: -0.01);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _adjust(saturation: 0.01);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _adjust(value: 0.01);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _adjust(value: -0.01);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  double _indicatorPosition(double fraction, double length) {
    final maxOffset =
        (length - AppSizes.colorPickerIndicator).clamp(0.0, double.infinity);
    return (fraction * length - AppSizes.colorPickerIndicator / 2)
        .clamp(0.0, maxOffset);
  }

  String _semanticsValue(HSVColor color) =>
      '饱和度 ${(color.saturation * 100).round()}%，'
      '明暗 ${(color.value * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hueColor = _color.withSaturation(1).withValue(1).toColor();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('调色板', style: AppText.body),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '横向调节鲜艳程度，纵向调节明暗，滑条选择色相。',
          style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        Semantics(
          label: '颜色面板',
          value: _semanticsValue(_color),
          increasedValue: _enabled
              ? _semanticsValue(_color
                  .withSaturation((_color.saturation + 0.01).clamp(0.0, 1.0)))
              : null,
          decreasedValue: _enabled
              ? _semanticsValue(_color
                  .withSaturation((_color.saturation - 0.01).clamp(0.0, 1.0)))
              : null,
          hint: '左右方向键调整饱和度，上下方向键调整明暗',
          enabled: _enabled,
          onIncrease: _enabled ? () => _adjust(saturation: 0.01) : null,
          onDecrease: _enabled ? () => _adjust(saturation: -0.01) : null,
          customSemanticsActions: _enabled
              ? {
                  const CustomSemanticsAction(label: '调亮'): () =>
                      _adjust(value: 0.01),
                  const CustomSemanticsAction(label: '调暗'): () =>
                      _adjust(value: -0.01),
                }
              : null,
          child: Focus(
            focusNode: _planeFocus,
            canRequestFocus: _enabled,
            onKeyEvent: _handleKey,
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: SizedBox(
              height: AppSizes.colorPickerPlane,
              width: double.infinity,
              child: LayoutBuilder(builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  key: const ValueKey('color-picker-plane'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: _enabled
                      ? (details) => _pickPosition(details.localPosition, size)
                      : null,
                  onPanStart: _enabled
                      ? (details) => _pickPosition(details.localPosition, size)
                      : null,
                  onPanUpdate: _enabled
                      ? (details) => _pickPosition(details.localPosition, size)
                      : null,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      borderRadius: AppRadius.controlAll,
                      border: Border.all(
                        color:
                            _focused ? scheme.primary : scheme.outlineVariant,
                        width: AppSizes.border,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: AppRadius.controlAll,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [AppColorPickerColors.light, hueColor],
                              ),
                            ),
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  AppColorPickerColors.dark
                                      .withValues(alpha: 0),
                                  AppColorPickerColors.dark,
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: _indicatorPosition(
                                _color.saturation, size.width),
                            top: _indicatorPosition(
                                1 - _color.value, size.height),
                            child: IgnorePointer(
                              child: Container(
                                width: AppSizes.colorPickerIndicator,
                                height: AppSizes.colorPickerIndicator,
                                decoration: BoxDecoration(
                                  color: _color.toColor(),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppColorPickerColors.light,
                                    width: AppSizes.border * 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColorPickerColors.dark
                                          .withValues(alpha: 0.5),
                                      blurRadius: AppSpacing.xs,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            const Expanded(child: Text('色相', style: AppText.caption)),
            Text('${_color.hue.round()}°', style: AppText.caption),
          ],
        ),
        Semantics(
          label: '色相',
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackShape: const _HueSliderTrackShape(),
              trackHeight: AppSpacing.sm,
              thumbColor: hueColor,
              overlayColor: hueColor.withValues(alpha: 0.12),
            ),
            child: Slider(
              value: _color.hue,
              min: 0,
              max: 360,
              semanticFormatterCallback: (value) => '${value.round()} 度',
              onChanged:
                  _enabled ? (hue) => _change(_color.withHue(hue)) : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _HueSliderTrackShape extends RoundedRectSliderTrackShape {
  const _HueSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final paint = Paint()
      ..shader = AppColorPickerColors.hueSpectrum.createShader(
        rect,
        textDirection: textDirection,
      );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      paint,
    );
  }
}
