import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/background_image_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// Full-window wallpaper placed below the Navigator by MaterialApp.builder.
class BackgroundImageLayer extends StatelessWidget {
  const BackgroundImageLayer({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final background = context.watch<BackgroundImageProvider>();
    final surfaces = AppSurfaces.of(context);
    final path = background.path;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: surfaces.page),
        if (background.isActive && path != null && background.opacity > 0)
          Positioned.fill(
            child: _PhotoImage(
              path: path,
              opacity: background.opacity,
            ),
          ),
        Positioned.fill(child: child),
      ],
    );
  }
}

/// Settings preview uses the same photo opacity as the app canvas.
class BackgroundImagePreview extends StatelessWidget {
  const BackgroundImagePreview({
    required this.path,
    required this.opacity,
    super.key,
  });

  final String? path;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final currentPath = path;

    return ClipRRect(
      borderRadius: AppRadius.cardAll,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: surfaces.page),
            if (currentPath != null && opacity > 0)
              _PhotoImage(path: currentPath, opacity: opacity),
            if (currentPath == null)
              Center(
                child: Icon(
                  Icons.wallpaper_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Gives overlay panels such as the settings drawer the same wallpaper pixels
/// as the app canvas beneath them. Without this local backing layer, a
/// translucent Drawer reveals the page body that it is covering instead of
/// revealing the wallpaper under the route.
class BackgroundImagePanelLayer extends StatelessWidget {
  const BackgroundImagePanelLayer({
    required this.panelColor,
    required this.child,
    this.panelOpacity = 0.72,
    super.key,
  });

  final Color panelColor;
  final double panelOpacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final background = context.watch<BackgroundImageProvider>();
    final surfaces = AppSurfaces.of(context);
    final path = background.path;
    final viewport = MediaQuery.sizeOf(context);
    final isActive = background.isActive;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (isActive && path != null)
            Positioned(
              left: 0,
              top: 0,
              width: viewport.width,
              height: viewport.height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: surfaces.page),
                  if (background.opacity > 0)
                    _PhotoImage(path: path, opacity: background.opacity),
                ],
              ),
            )
          else
            ColoredBox(color: surfaces.page),
          ColoredBox(
            color: panelColor.withValues(
              alpha: isActive ? panelOpacity.clamp(0.0, 1.0) : 1,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _PhotoImage extends StatelessWidget {
  const _PhotoImage({required this.path, required this.opacity});

  final String path;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.sizeOf(context);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (mediaSize.longestSide * devicePixelRatio)
        .round()
        .clamp(1, 2560)
        .toInt();

    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        errorBuilder: (context, error, stackTrace) => const SizedBox.expand(),
      ),
    );
  }
}
