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

/// Android 桌面小组件（`home_widget` 插件）只在 Android 上有实现。
/// 注意 iOS 不是桌面端，会落进移动端分支，必须单独按 Android 判定，
/// 否则会调用未配置的小组件插件并抛出 `AppGroupId not set`。
bool supportsHomeWidgetFor({required bool android}) => android;

bool get supportsHomeWidget =>
    supportsHomeWidgetFor(android: Platform.isAndroid);

/// 应用内自更新通道：Android（APK）、Windows（EXE）、macOS（DMG）都有安装包，
/// **iOS 没有**——iOS 只能通过 Xcode / App Store 更新，无法下载安装包自更新。
bool supportsInAppUpdateFor({required bool ios}) => !ios;

bool get supportsInAppUpdate =>
    supportsInAppUpdateFor(ios: Platform.isIOS);

String updateAssetSuffixFor({required bool windows, required bool macos}) {
  if (windows) return '.exe';
  if (macos) return '.dmg';
  return '.apk';
}

String get updateAssetSuffix => updateAssetSuffixFor(
      windows: Platform.isWindows,
      macos: Platform.isMacOS,
    );
