import 'dart:io';

/// Windows and macOS share the desktop workflow in this application.
bool get isDesktopPlatform =>
    isDesktopPlatformFor(windows: Platform.isWindows, macos: Platform.isMacOS);

bool isDesktopPlatformFor({required bool windows, required bool macos}) =>
    windows || macos;

String updateAssetSuffixFor({required bool windows, required bool macos}) {
  if (windows) return '.exe';
  if (macos) return '.dmg';
  return '.apk';
}

String get updateAssetSuffix => updateAssetSuffixFor(
      windows: Platform.isWindows,
      macos: Platform.isMacOS,
    );
