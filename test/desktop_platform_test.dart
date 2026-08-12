import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/platform_features.dart';

void main() {
  test('macOS is treated as a Windows-compatible desktop platform', () {
    expect(isDesktopPlatformFor(windows: false, macos: true), isTrue);
  });

  test('Android remains a non-desktop platform', () {
    expect(isDesktopPlatformFor(windows: false, macos: false), isFalse);
  });

  test('desktop update assets use platform installers', () {
    expect(updateAssetSuffixFor(windows: true, macos: false), '.exe');
    expect(updateAssetSuffixFor(windows: false, macos: true), '.dmg');
    expect(updateAssetSuffixFor(windows: false, macos: false), '.apk');
  });
}
