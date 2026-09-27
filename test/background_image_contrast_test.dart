import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/background_image_contrast.dart';

void main() {
  test('safe wallpaper opacity preserves AA text and icon contrast', () {
    for (final brightness in Brightness.values) {
      final theme = brightness == Brightness.light
          ? AppTheme.light(backgroundEnabled: true)
          : AppTheme.dark(backgroundEnabled: true);
      final wallpaper = theme.extension<AppWallpaperTheme>()!;
      final surfaces = theme.extension<AppSurfaces>()!;
      expect(surfaces.gridEmpty.a, closeTo(0.45, 1e-6));
      expect(surfaces.sidebar.a, closeTo(0.72, 1e-6));
      final worstBackdrop = BackgroundImageContrast.worstPhotoBackdrop(
        brightness: brightness,
        pageColor: surfaces.page,
        photoOpacity: wallpaper.safePhotoOpacity,
      );

      expect(
        BackgroundImageContrast.contrastRatio(
          theme.colorScheme.onSurface,
          worstBackdrop,
        ),
        greaterThanOrEqualTo(4.5),
        reason: '$brightness primary text',
      );
      for (final textColor in [
        theme.colorScheme.onSurfaceVariant,
        theme.colorScheme.outline,
        theme.colorScheme.outlineVariant,
      ]) {
        expect(
          BackgroundImageContrast.contrastRatio(textColor, worstBackdrop),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness secondary text: $textColor',
        );
      }
      expect(wallpaper.safePhotoOpacity, inInclusiveRange(0.0, 1.0));
    }
  });

  test('a wallpaper-free theme keeps its original opaque page and panels', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final surfaces = theme.extension<AppSurfaces>()!;
      final wallpaper = theme.extension<AppWallpaperTheme>()!;
      expect(theme.scaffoldBackgroundColor, surfaces.page);
      expect(theme.appBarTheme.backgroundColor, surfaces.panel);
      expect(theme.navigationBarTheme.backgroundColor, surfaces.panel);
      expect(surfaces.gridEmpty.a, 1);
      expect(surfaces.sidebar, surfaces.subtle);
      expect(wallpaper.enabled, isFalse);
    }
  });
}
