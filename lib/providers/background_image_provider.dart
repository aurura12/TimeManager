import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Result of selecting and copying a local background image.
enum BackgroundImagePickResult {
  applied,
  cancelled,
  tooLarge,
  unavailable,
  failed,
}

/// Device-only state for the optional full-window background image.
///
/// This provider intentionally stays separate from the business data provider:
/// the local image path must never enter sync or backup snapshots.
class BackgroundImageProvider extends ChangeNotifier {
  BackgroundImageProvider({
    Future<SharedPreferences> Function()? preferencesLoader,
    Future<Directory> Function()? applicationSupportDirectory,
    Future<FilePickerResult?> Function()? imagePicker,
    DateTime Function()? clock,
  })  : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _applicationSupportDirectory =
            applicationSupportDirectory ?? getApplicationSupportDirectory,
        _imagePicker = imagePicker ?? _pickImageFile,
        _clock = clock ?? DateTime.now;

  static const preferencePathKey = 'background_image_path_v1';
  static const preferenceEnabledKey = 'background_image_enabled_v1';
  static const preferenceOpacityKey = 'background_image_opacity_v1';
  static const defaultOpacity = 0.15;
  static const maxPhotoBytes = 32 * 1024 * 1024;
  static const _directoryName = 'time_manager/backgrounds';

  final Future<SharedPreferences> Function() _preferencesLoader;
  final Future<Directory> Function() _applicationSupportDirectory;
  final Future<FilePickerResult?> Function() _imagePicker;
  final DateTime Function() _clock;

  String? _path;
  bool _enabled = false;
  bool _exists = false;
  double _opacity = defaultOpacity;
  bool _loaded = false;

  String? get path => _path;
  bool get enabled => _enabled;

  /// Cached file existence. This value is only refreshed outside build methods.
  bool get exists => _exists;

  double get opacity => _opacity;
  bool get isLoaded => _loaded;
  bool get isActive => _enabled && _path != null && _exists;
  bool get hasPhoto => _path != null && _exists;

  /// Reads preferences only. File-system validation is a separate operation.
  Future<void> load() async {
    final prefs = await _preferencesLoader();
    _path = prefs.getString(preferencePathKey);
    _enabled = prefs.getBool(preferenceEnabledKey) ?? false;
    _opacity = (prefs.getDouble(preferenceOpacityKey) ?? defaultOpacity)
        .clamp(0.0, 1.0)
        .toDouble();
    _exists = false;
    _loaded = true;
    notifyListeners();
  }

  /// Validates the saved file once during startup or after an explicit action.
  ///
  /// Keeping this out of [load] lets preference state be unit-tested without a
  /// path-provider platform channel, and keeping it out of build avoids I/O in
  /// rendering.
  Future<void> validateStoredPhoto() async {
    final storedPath = _path;
    if (storedPath == null) {
      if (_exists) {
        _exists = false;
        notifyListeners();
      }
      return;
    }

    bool fileExists;
    try {
      fileExists = await File(storedPath).exists();
    } on Object {
      fileExists = false;
    }
    if (!fileExists) {
      final prefs = await _preferencesLoader();
      await prefs.remove(preferencePathKey);
      await prefs.setBool(preferenceEnabledKey, false);
      _path = null;
      _enabled = false;
      _exists = false;
      notifyListeners();
      return;
    }

    if (!_exists) {
      _exists = true;
      notifyListeners();
    }
  }

  /// Loads preferences, then checks the saved file without blocking startup.
  Future<void> initialize() async {
    try {
      await load();
      await validateStoredPhoto();
    } on Object {
      // Background preferences are optional and must not block app startup.
    }
  }

  Future<BackgroundImagePickResult> pickAndApply() async {
    FilePickerResult? selection;
    try {
      selection = await _imagePicker();
    } on Object {
      return BackgroundImagePickResult.failed;
    }
    if (selection == null || selection.files.isEmpty) {
      return BackgroundImagePickResult.cancelled;
    }

    final selected = selection.files.first;
    final sourcePath = selected.path;
    if (sourcePath == null || sourcePath.isEmpty) {
      return BackgroundImagePickResult.unavailable;
    }

    final source = File(sourcePath);
    try {
      // Check picker metadata and the actual temporary file before copying any
      // bytes. The second check also covers providers with stale metadata.
      if (selected.size > maxPhotoBytes) {
        return BackgroundImagePickResult.tooLarge;
      }
      if (!await source.exists()) return BackgroundImagePickResult.unavailable;
      if (await source.length() > maxPhotoBytes) {
        return BackgroundImagePickResult.tooLarge;
      }
    } on Object {
      return BackgroundImagePickResult.unavailable;
    }

    File? destination;
    try {
      final supportDirectory = await _applicationSupportDirectory();
      final imageDirectory = Directory(p.join(
        supportDirectory.path,
        _directoryName,
      ));
      await imageDirectory.create(recursive: true);

      final extension = _safeExtension(selected.name);
      final timestamp = _clock().microsecondsSinceEpoch;
      var candidate = File(p.join(
        imageDirectory.path,
        'background_$timestamp$extension',
      ));
      var suffix = 1;
      while (await candidate.exists()) {
        candidate = File(p.join(
          imageDirectory.path,
          'background_${timestamp}_$suffix$extension',
        ));
        suffix++;
      }
      destination = candidate;

      final copyResult = await _copyWithLimit(source, destination);
      if (copyResult == _LimitedCopyResult.tooLarge) {
        await _deleteQuietly(destination);
        return BackgroundImagePickResult.tooLarge;
      }

      final newPath = destination.absolute.path;
      final prefs = await _preferencesLoader();
      final previousPath = _path;
      final previousEnabled = _enabled;
      bool pathSaved;
      bool enabledSaved;
      try {
        pathSaved = await prefs.setString(preferencePathKey, newPath);
        enabledSaved =
            pathSaved && await prefs.setBool(preferenceEnabledKey, true);
      } on Object {
        await _restorePathPreferences(
          prefs,
          path: previousPath,
          enabled: previousEnabled,
        );
        rethrow;
      }
      if (!pathSaved || !enabledSaved) {
        await _restorePathPreferences(
          prefs,
          path: previousPath,
          enabled: previousEnabled,
        );
        await _deleteQuietly(destination);
        return BackgroundImagePickResult.failed;
      }

      // Commit and persist the replacement before deleting the old image.
      _path = newPath;
      _enabled = true;
      _exists = true;
      notifyListeners();
      if (previousPath != null && previousPath != newPath) {
        await _deleteQuietly(File(previousPath));
      }
      return BackgroundImagePickResult.applied;
    } on Object {
      if (destination != null) await _deleteQuietly(destination);
      return BackgroundImagePickResult.failed;
    }
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await _preferencesLoader();
    final saved = await prefs.setBool(preferenceEnabledKey, value);
    if (!saved) throw StateError('Background preference could not be saved');
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }

  /// Updates the slider immediately; callers persist only from onChangeEnd.
  void setOpacity(double value) {
    final next = value.clamp(0.0, 1.0).toDouble();
    if (_opacity == next) return;
    _opacity = next;
    notifyListeners();
  }

  Future<void> commitOpacity() async {
    final prefs = await _preferencesLoader();
    final saved = await prefs.setDouble(
      preferenceOpacityKey,
      _opacity.clamp(0.0, 1.0).toDouble(),
    );
    if (!saved) throw StateError('Background opacity could not be saved');
  }

  Future<void> clear() async {
    final previousPath = _path;
    final prefs = await _preferencesLoader();
    final pathRemoved = await prefs.remove(preferencePathKey);
    await prefs.setBool(preferenceEnabledKey, false);
    if (!pathRemoved && prefs.getString(preferencePathKey) != null) {
      return;
    }

    _path = null;
    _enabled = false;
    _exists = false;
    notifyListeners();
    if (previousPath != null) await _deleteQuietly(File(previousPath));
  }

  static Future<FilePickerResult?> _pickImageFile() {
    return FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
  }

  static String _safeExtension(String fileName) {
    final extension = p.extension(fileName).toLowerCase();
    if (RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) return extension;
    return '.img';
  }

  static Future<_LimitedCopyResult> _copyWithLimit(
    File source,
    File destination,
  ) async {
    var copiedBytes = 0;
    var tooLarge = false;
    final sink = destination.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        if (copiedBytes + chunk.length > maxPhotoBytes) {
          tooLarge = true;
          break;
        }
        sink.add(chunk);
        copiedBytes += chunk.length;
      }
      await sink.flush();
      await sink.close();
    } on Object {
      try {
        await sink.close();
      } on Object {
        // Preserve the original copy failure.
      }
      rethrow;
    }
    return tooLarge ? _LimitedCopyResult.tooLarge : _LimitedCopyResult.copied;
  }

  Future<void> _restorePathPreferences(
    SharedPreferences prefs, {
    required String? path,
    required bool enabled,
  }) async {
    if (path == null) {
      await prefs.remove(preferencePathKey);
    } else {
      await prefs.setString(preferencePathKey, path);
    }
    await prefs.setBool(preferenceEnabledKey, enabled);
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // A stale orphan is harmless; do not lose the successfully saved image.
    }
  }
}

enum _LimitedCopyResult { copied, tooLarge }
