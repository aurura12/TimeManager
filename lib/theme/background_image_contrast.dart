import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Contrast calculations used by the wallpaper layer and its settings preview.
///
/// Compositing is done channel-by-channel in sRGB, matching the documented
/// wallpaper contract instead of relying on a renderer's blend mode.
abstract final class BackgroundImageContrast {
  static const bodyTextRatio = 4.5;

  static Color composite(Color foreground, Color background) {
    final alpha = foreground.a;
    return Color.from(
      alpha: 1,
      red: foreground.r * alpha + background.r * (1 - alpha),
      green: foreground.g * alpha + background.g * (1 - alpha),
      blue: foreground.b * alpha + background.b * (1 - alpha),
    );
  }

  static double contrastRatio(Color first, Color second) {
    final firstLuminance = relativeLuminance(first);
    final secondLuminance = relativeLuminance(second);
    final lighter =
        firstLuminance > secondLuminance ? firstLuminance : secondLuminance;
    final darker =
        firstLuminance < secondLuminance ? firstLuminance : secondLuminance;
    return (lighter + 0.05) / (darker + 0.05);
  }

  static double relativeLuminance(Color color) {
    double linearize(double channel) {
      return channel <= 0.03928
          ? channel / 12.92
          : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * linearize(color.r) +
        0.7152 * linearize(color.g) +
        0.0722 * linearize(color.b);
  }

  /// Computes the highest photo opacity that keeps text and icon colors
  /// readable on the page in the worst-case photo.
  static double safePhotoOpacity({
    required Brightness brightness,
    required Color pageColor,
    required Color onSurface,
    required Color onSurfaceVariant,
    required Color outline,
  }) {
    final worstPhoto = brightness == Brightness.light
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);

    bool isReadableAt(double opacity) {
      final background = composite(
        worstPhoto.withValues(alpha: opacity),
        pageColor,
      );
      return contrastRatio(onSurface, background) >= bodyTextRatio &&
          contrastRatio(onSurfaceVariant, background) >= bodyTextRatio &&
          contrastRatio(outline, background) >= 3;
    }

    if (!isReadableAt(0)) return 0;
    if (isReadableAt(1)) return 1;

    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 28; i++) {
      final middle = (low + high) / 2;
      if (isReadableAt(middle)) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// Moves a theme foreground toward black or white only as far as needed to
  /// meet AA on the darkest/lightest possible wallpaper background.
  static Color readableForeground({
    required Color foreground,
    required Color background,
    required Brightness brightness,
    double minimumRatio = bodyTextRatio,
  }) {
    if (contrastRatio(foreground, background) >= minimumRatio) {
      return foreground;
    }
    final target = brightness == Brightness.light
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 28; i++) {
      final middle = (low + high) / 2;
      final candidate = Color.lerp(foreground, target, middle)!;
      if (contrastRatio(candidate, background) >= minimumRatio) {
        high = middle;
      } else {
        low = middle;
      }
    }
    return Color.lerp(foreground, target, high)!;
  }

  static Color worstPhotoBackdrop({
    required Brightness brightness,
    required Color pageColor,
    required double photoOpacity,
  }) {
    final worstPhoto = brightness == Brightness.light
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
    return composite(worstPhoto.withValues(alpha: photoOpacity), pageColor);
  }
}
