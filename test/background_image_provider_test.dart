import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/providers/background_image_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load reads preferences only and clamps persisted opacity', () async {
    SharedPreferences.setMockInitialValues({
      BackgroundImageProvider.preferencePathKey: '/missing/local/photo.png',
      BackgroundImageProvider.preferenceEnabledKey: true,
      BackgroundImageProvider.preferenceOpacityKey: 1.5,
      BackgroundImageProvider.preferenceSurfaceOpacityKey: 0.05,
    });
    var directoryLookups = 0;
    final provider = BackgroundImageProvider(
      applicationSupportDirectory: () async {
        directoryLookups++;
        throw StateError('load must not access the file system');
      },
    );
    addTearDown(provider.dispose);

    await provider.load();

    expect(provider.path, '/missing/local/photo.png');
    expect(provider.enabled, isTrue);
    expect(provider.exists, isFalse);
    expect(provider.hasPhoto, isFalse);
    expect(provider.opacity, 1);
    expect(
      provider.surfaceOpacity,
      BackgroundImageProvider.minSurfaceOpacity,
    );
    expect(directoryLookups, 0);
  });

  test('opacity changes are persisted only by commitOpacity', () async {
    SharedPreferences.setMockInitialValues({
      BackgroundImageProvider.preferenceOpacityKey: 0.15,
    });
    final provider = BackgroundImageProvider();
    addTearDown(provider.dispose);
    final prefs = await SharedPreferences.getInstance();
    await provider.load();

    provider.setOpacity(0.73);
    expect(provider.opacity, 0.73);
    expect(prefs.getDouble(BackgroundImageProvider.preferenceOpacityKey), 0.15);

    await provider.commitOpacity();
    expect(prefs.getDouble(BackgroundImageProvider.preferenceOpacityKey), 0.73);
  });

  test('surfaceOpacity defaults, clamps, and persists only on commit',
      () async {
    SharedPreferences.setMockInitialValues({});
    final provider = BackgroundImageProvider();
    addTearDown(provider.dispose);
    final prefs = await SharedPreferences.getInstance();
    await provider.load();

    expect(
      provider.surfaceOpacity,
      BackgroundImageProvider.defaultSurfaceOpacity,
    );

    // 越界值收到允许区间
    provider.setSurfaceOpacity(0.05);
    expect(
      provider.surfaceOpacity,
      BackgroundImageProvider.minSurfaceOpacity,
    );
    provider.setSurfaceOpacity(1.5);
    expect(provider.surfaceOpacity, 1.0);

    // 只改内存，不落盘
    provider.setSurfaceOpacity(0.5);
    expect(provider.surfaceOpacity, 0.5);
    expect(
      prefs.getDouble(BackgroundImageProvider.preferenceSurfaceOpacityKey),
      isNull,
    );

    await provider.commitSurfaceOpacity();
    expect(
      prefs.getDouble(BackgroundImageProvider.preferenceSurfaceOpacityKey),
      0.5,
    );

    // 重新 load 时读回持久值
    provider.setSurfaceOpacity(1.0);
    await provider.load();
    expect(provider.surfaceOpacity, 0.5);
  });

  test('startup validation clears a saved path whose file was removed',
      () async {
    SharedPreferences.setMockInitialValues({
      BackgroundImageProvider.preferencePathKey: '/missing/local/photo.png',
      BackgroundImageProvider.preferenceEnabledKey: true,
    });
    final provider = BackgroundImageProvider();
    addTearDown(provider.dispose);
    final prefs = await SharedPreferences.getInstance();
    await provider.load();

    expect(provider.path, '/missing/local/photo.png');
    expect(provider.exists, isFalse);

    await provider.validateStoredPhoto();

    expect(provider.path, isNull);
    expect(provider.enabled, isFalse);
    expect(provider.hasPhoto, isFalse);
    expect(prefs.getString(BackgroundImageProvider.preferencePathKey), isNull);
  });

  test('pick copies into private storage before removing the previous photo',
      () async {
    final temporary = await Directory.systemTemp.createTemp('background-test');
    addTearDown(() => temporary.delete(recursive: true));
    final source = File(p.join(temporary.path, 'selected.png'));
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    final oldPhoto = File(p.join(temporary.path, 'old.png'));
    await oldPhoto.writeAsBytes(<int>[5, 6]);
    final fixedClock = DateTime(2026, 9, 27, 10, 11, 12, 13, 14);
    SharedPreferences.setMockInitialValues({
      BackgroundImageProvider.preferencePathKey: oldPhoto.path,
      BackgroundImageProvider.preferenceEnabledKey: false,
    });
    final provider = BackgroundImageProvider(
      applicationSupportDirectory: () async => temporary,
      imagePicker: () async => FilePickerResult(<PlatformFile>[
        PlatformFile(name: 'selected.png', size: 4, path: source.path),
      ]),
      clock: () => fixedClock,
    );
    addTearDown(provider.dispose);
    final prefs = await SharedPreferences.getInstance();
    await provider.load();
    await provider.validateStoredPhoto();

    final result = await provider.pickAndApply();

    expect(result, BackgroundImagePickResult.applied);
    expect(provider.isActive, isTrue);
    expect(provider.path, isNot(source.path));
    expect(
      provider.path,
      contains('background_${fixedClock.microsecondsSinceEpoch}.png'),
    );
    expect(await File(provider.path!).readAsBytes(), <int>[1, 2, 3, 4]);
    expect(await oldPhoto.exists(), isFalse);
    expect(await source.exists(), isTrue);
    expect(prefs.getString(BackgroundImageProvider.preferencePathKey),
        provider.path);
    expect(prefs.getBool(BackgroundImageProvider.preferenceEnabledKey), isTrue);
  });

  test('picker cancellation and oversized image are normal results', () async {
    final provider = BackgroundImageProvider(
      imagePicker: () async => null,
    );
    addTearDown(provider.dispose);
    expect(await provider.pickAndApply(), BackgroundImagePickResult.cancelled);

    final oversizedProvider = BackgroundImageProvider(
      imagePicker: () async => FilePickerResult(<PlatformFile>[
        PlatformFile(
          name: 'large.png',
          size: BackgroundImageProvider.maxPhotoBytes + 1,
          path: '/not-read/large.png',
        ),
      ]),
    );
    addTearDown(oversizedProvider.dispose);
    expect(
      await oversizedProvider.pickAndApply(),
      BackgroundImagePickResult.tooLarge,
    );
  });

  test('clear removes the photo and preserves opacity', () async {
    final temporary = await Directory.systemTemp.createTemp('background-clear');
    addTearDown(() => temporary.delete(recursive: true));
    final photo = File(p.join(temporary.path, 'photo.png'));
    await photo.writeAsBytes(<int>[1, 2, 3]);
    SharedPreferences.setMockInitialValues({
      BackgroundImageProvider.preferencePathKey: photo.path,
      BackgroundImageProvider.preferenceEnabledKey: true,
      BackgroundImageProvider.preferenceOpacityKey: 0.44,
      BackgroundImageProvider.preferenceSurfaceOpacityKey: 0.5,
    });
    final provider = BackgroundImageProvider();
    addTearDown(provider.dispose);
    final prefs = await SharedPreferences.getInstance();
    await provider.load();
    await provider.validateStoredPhoto();

    await provider.clear();

    expect(provider.path, isNull);
    expect(provider.enabled, isFalse);
    expect(provider.opacity, 0.44);
    expect(prefs.getDouble(BackgroundImageProvider.preferenceOpacityKey), 0.44);
    expect(provider.surfaceOpacity, 0.5);
    expect(
      prefs.getDouble(BackgroundImageProvider.preferenceSurfaceOpacityKey),
      0.5,
    );
    expect(await photo.exists(), isFalse);
  });
}
