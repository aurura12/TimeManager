import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/background_image_contrast.dart';

void main() {
  test('所有主题色及极端自定义色保留浅深色和背景图的对比度契约', () {
    for (final color in [
      ...AppThemeColorPreset.values.map((preset) => preset.color),
      Colors.black,
      Colors.white,
      const Color(0x80FFFFFF),
    ]) {
      for (final brightness in Brightness.values) {
        for (final backgroundEnabled in [false, true]) {
          final theme = AppTheme.themeFor(
            brightness,
            seedColor: color,
            backgroundEnabled: backgroundEnabled,
            surfaceOpacity: 0.4,
          );
          final scheme = theme.colorScheme;
          final expectedScheme = ColorScheme.fromSeed(
            seedColor: AppSemanticColors.opaque(color),
            brightness: brightness,
          );
          expect(scheme.primary, expectedScheme.primary);
          expect(scheme.primaryContainer, expectedScheme.primaryContainer);
          for (final pair in [
            (scheme.primary, scheme.onPrimary),
            (scheme.primaryContainer, scheme.onPrimaryContainer),
          ]) {
            expect(
              BackgroundImageContrast.contrastRatio(pair.$1, pair.$2),
              greaterThanOrEqualTo(BackgroundImageContrast.bodyTextRatio),
            );
          }
          final surfaces = theme.extension<AppSurfaces>()!;
          final wallpaper = theme.extension<AppWallpaperTheme>()!;
          final backdrop = backgroundEnabled
              ? BackgroundImageContrast.worstPhotoBackdrop(
                  brightness: brightness,
                  pageColor: surfaces.page,
                  photoOpacity: wallpaper.safePhotoOpacity,
                )
              : surfaces.page;
          for (final foreground in [
            scheme.onSurface,
            scheme.onSurfaceVariant,
          ]) {
            expect(
              BackgroundImageContrast.contrastRatio(foreground, backdrop),
              greaterThanOrEqualTo(BackgroundImageContrast.bodyTextRatio),
              reason: '$color / $brightness / wallpaper=$backgroundEnabled',
            );
          }
          expect(surfaces.overlay.a, 1);
          expect(scheme.surfaceContainerHigh.a, 1);
          expect(surfaces.card.a, closeTo(backgroundEnabled ? 0.4 : 1, 1e-6));
        }
      }
    }
  });

  test('safe wallpaper opacity preserves AA text and icon contrast', () {
    for (final brightness in Brightness.values) {
      final theme = brightness == Brightness.light
          ? AppTheme.light(backgroundEnabled: true)
          : AppTheme.dark(backgroundEnabled: true);
      final wallpaper = theme.extension<AppWallpaperTheme>()!;
      final surfaces = theme.extension<AppSurfaces>()!;
      expect(surfaces.gridEmpty.a, closeTo(0.45, 1e-6));
      expect(surfaces.sidebar.a, closeTo(0.72, 1e-6));
      // 界面表面跟随「界面不透明度」变半透明，照片才能透出来
      expect(surfaces.card.a, closeTo(0.72, 1e-6));
      expect(surfaces.panel.a, closeTo(0.72, 1e-6));
      expect(surfaces.subtle.a, closeTo(0.72, 1e-6));
      expect(wallpaper.surfaceOpacity, closeTo(0.72, 1e-6));
      expect(theme.colorScheme.surfaceContainerLow.a, closeTo(0.72, 1e-6));
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
      // 没有壁纸时界面表面必须完全不透明，不能跟着不透明度变透
      expect(surfaces.card.a, 1);
      expect(surfaces.panel.a, 1);
      expect(surfaces.subtle.a, 1);
      expect(surfaces.overlay.a, 1);
      expect(theme.colorScheme.surface.a, 1);
      expect(theme.colorScheme.surfaceContainerLow.a, 1);
      expect(wallpaper.enabled, isFalse);
    }
  });

  test('surfaceOpacity 只影响内容面，浮层与 High 档始终不透明', () {
    for (final theme in [
      AppTheme.light(backgroundEnabled: true, surfaceOpacity: 0.4),
      AppTheme.dark(backgroundEnabled: true, surfaceOpacity: 0.4),
    ]) {
      final surfaces = theme.extension<AppSurfaces>()!;
      expect(surfaces.card.a, closeTo(0.4, 1e-6));
      expect(surfaces.panel.a, closeTo(0.4, 1e-6));
      expect(surfaces.subtle.a, closeTo(0.4, 1e-6));
      expect(theme.colorScheme.surfaceContainerLow.a, closeTo(0.4, 1e-6));
      // 浮层压在 scrim 上，必须不透明
      expect(surfaces.overlay.a, 1);
      // High/Highest 不覆盖：DatePicker/TimePicker 与 adaptSemanticColor 依赖它不透明
      expect(theme.colorScheme.surfaceContainerHigh.a, 1);
      expect(theme.colorScheme.surfaceContainerHighest.a, 1);
      expect(theme.scaffoldBackgroundColor, Colors.transparent);
    }
  });
}
