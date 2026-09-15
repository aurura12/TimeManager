import 'dart:io';

/// Windows and macOS share the desktop workflow in this application.
bool get isDesktopPlatform =>
    isDesktopPlatformFor(windows: Platform.isWindows, macos: Platform.isMacOS);

bool isDesktopPlatformFor({required bool windows, required bool macos}) =>
    windows || macos;

/// 仅移动端支持直接拍照。桌面端保留相册选择和已有照片流程，
/// 不暴露 ImageSource.camera 入口。
bool supportsCameraCaptureFor({required bool windows, required bool macos}) =>
    !isDesktopPlatformFor(windows: windows, macos: macos);

bool get supportsCameraCapture => supportsCameraCaptureFor(
      windows: Platform.isWindows,
      macos: Platform.isMacOS,
    );

bool useImmediateDragFor({required bool windows, required bool macos}) =>
    isDesktopPlatformFor(windows: windows, macos: macos);

bool get useImmediateDrag =>
    useImmediateDragFor(windows: Platform.isWindows, macos: Platform.isMacOS);

String updateAssetSuffixFor({required bool windows, required bool macos}) {
  if (windows) return '.exe';
  if (macos) return '.dmg';
  return '.apk';
}

String get updateAssetSuffix => updateAssetSuffixFor(
      windows: Platform.isWindows,
      macos: Platform.isMacOS,
    );
