import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef ApplicationSupportDirectoryProvider = Future<Directory> Function();

enum WindowsLegacyMigrationStatus {
  skippedNonWindows,
  alreadyMigrated,
  noLegacyData,
  migrated,
  failed,
}

class WindowsLegacyMigrationResult {
  const WindowsLegacyMigrationResult(
    this.status, {
    this.migratedKeyCount = 0,
    this.error,
  });

  final WindowsLegacyMigrationStatus status;
  final int migratedKeyCount;
  final Object? error;

  bool get didMigrate => status == WindowsLegacyMigrationStatus.migrated;
}

class WindowsLegacyPreferencesMigration {
  WindowsLegacyPreferencesMigration({
    ApplicationSupportDirectoryProvider? applicationSupportDirectoryProvider,
    bool? isWindows,
  })  : _applicationSupportDirectoryProvider =
            applicationSupportDirectoryProvider ??
                getApplicationSupportDirectory,
        _isWindows = isWindows;

  static const String migrationMarkerKey =
      'flutter.windows_legacy_preferences_migrated_v1';
  static const String _preferencesFileName = 'shared_preferences.json';
  static const String _legacyProductName = 'time_manager';
  static const String _dailySlotsKey = 'flutter.daily_slots';
  static const Set<String> _schedulePreferenceKeys = <String>{
    'flutter.categories',
    'flutter.deleted_categories',
    'flutter.categories_doc_updated_at',
    _dailySlotsKey,
    'flutter.schedule_templates',
    'flutter.ignored_calendar_imports',
    'flutter.pending_gitee_sync_dates',
    'flutter.pending_google_sync_dates',
    'flutter.pending_sync_dates',
    'flutter.category_expand_states',
  };

  final ApplicationSupportDirectoryProvider
      _applicationSupportDirectoryProvider;
  final bool? _isWindows;

  Future<WindowsLegacyMigrationResult> migrate() async {
    if (!(_isWindows ?? Platform.isWindows)) {
      return const WindowsLegacyMigrationResult(
        WindowsLegacyMigrationStatus.skippedNonWindows,
      );
    }

    try {
      final currentDirectory = await _applicationSupportDirectoryProvider();
      final currentFile =
          File(p.join(currentDirectory.path, _preferencesFileName));
      final tempFile = File(
        '${currentFile.path}.windows_legacy_preferences.tmp',
      );
      await _recoverTemporaryFile(currentFile, tempFile);

      final legacyFile = File(
        p.join(
          p.dirname(currentDirectory.path),
          _legacyProductName,
          _preferencesFileName,
        ),
      );
      final currentExists = await currentFile.exists();
      final currentPreferences = currentExists
          ? await _readPreferences(currentFile)
          : <String, dynamic>{};
      if (currentPreferences[migrationMarkerKey] == true) {
        return const WindowsLegacyMigrationResult(
          WindowsLegacyMigrationStatus.alreadyMigrated,
        );
      }

      if (!await legacyFile.exists() ||
          _samePath(currentFile.path, legacyFile.path)) {
        return const WindowsLegacyMigrationResult(
          WindowsLegacyMigrationStatus.noLegacyData,
        );
      }

      final legacyPreferences = await _readPreferences(legacyFile);
      final mergedPreferences = <String, dynamic>{...currentPreferences};
      var migratedKeyCount = 0;
      for (final entry in legacyPreferences.entries) {
        if (!_schedulePreferenceKeys.contains(entry.key)) continue;
        if (!mergedPreferences.containsKey(entry.key)) {
          mergedPreferences[entry.key] = entry.value;
          migratedKeyCount++;
          continue;
        }
        if (entry.key == _dailySlotsKey) {
          final mergedSlots = _mergeDailySlots(
            mergedPreferences[entry.key],
            entry.value,
          );
          if (mergedSlots != mergedPreferences[entry.key]) {
            mergedPreferences[entry.key] = mergedSlots;
            migratedKeyCount++;
          }
        }
      }
      mergedPreferences[migrationMarkerKey] = true;

      File? currentBackup;
      try {
        await currentFile.parent.create(recursive: true);
        await tempFile.writeAsString(
          jsonEncode(mergedPreferences),
          flush: true,
        );
        if (currentExists) {
          currentBackup = File(
            '${currentFile.path}.before_windows_legacy_migration',
          );
          if (!await currentBackup.exists()) {
            await currentFile.copy(currentBackup.path);
          }
          await currentFile.delete();
        }
        await tempFile.rename(currentFile.path);
      } catch (error) {
        await _restoreAfterWriteFailure(
          currentFile,
          tempFile,
          currentBackup,
          currentExists: currentExists,
        );
        return WindowsLegacyMigrationResult(
          WindowsLegacyMigrationStatus.failed,
          error: error,
        );
      }

      return WindowsLegacyMigrationResult(
        WindowsLegacyMigrationStatus.migrated,
        migratedKeyCount: migratedKeyCount,
      );
    } catch (error) {
      return WindowsLegacyMigrationResult(
        WindowsLegacyMigrationStatus.failed,
        error: error,
      );
    }
  }

  Future<void> _recoverTemporaryFile(File currentFile, File tempFile) async {
    if (!await tempFile.exists()) return;
    if (await currentFile.exists()) {
      await tempFile.delete();
      return;
    }
    try {
      await _readPreferences(tempFile);
      await currentFile.parent.create(recursive: true);
      await tempFile.rename(currentFile.path);
    } catch (_) {
      try {
        await tempFile.delete();
      } catch (_) {
        // Leave an unreadable temporary file for manual recovery.
      }
    }
  }

  Future<Map<String, dynamic>> _readPreferences(File file) async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('SharedPreferences file is not an object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  dynamic _mergeDailySlots(dynamic current, dynamic legacy) {
    if (current is! String || legacy is! String) return current;
    if (current.isEmpty) return legacy;

    try {
      final currentDecoded = jsonDecode(current);
      final legacyDecoded = jsonDecode(legacy);
      if (currentDecoded is! Map || legacyDecoded is! Map) return current;

      final merged = <String, dynamic>{
        ...Map<String, dynamic>.from(currentDecoded),
      };
      for (final entry in legacyDecoded.entries) {
        final dateKey = entry.key.toString();
        if (!merged.containsKey(dateKey)) {
          merged[dateKey] = entry.value;
          continue;
        }

        final currentDay = merged[dateKey];
        final legacyDay = entry.value;
        if (currentDay is! List || legacyDay is! List) continue;

        final mergedDay = List<dynamic>.from(currentDay);
        final existingIndexes = <int>{};
        for (final slot in mergedDay) {
          if (slot is Map) {
            final index = _slotIndex(slot['i']);
            if (index != null) existingIndexes.add(index);
          }
        }
        for (final slot in legacyDay) {
          if (slot is! Map) continue;
          final index = _slotIndex(slot['i']);
          if (index == null || existingIndexes.contains(index)) continue;
          mergedDay.add(slot);
          existingIndexes.add(index);
        }
        merged[dateKey] = mergedDay;
      }
      return jsonEncode(merged);
    } catch (_) {
      return current;
    }
  }

  int? _slotIndex(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  Future<void> _restoreAfterWriteFailure(
    File currentFile,
    File tempFile,
    File? currentBackup, {
    required bool currentExists,
  }) async {
    try {
      if (currentBackup != null && await currentBackup.exists()) {
        await currentBackup.copy(currentFile.path);
      } else if (!currentExists && await currentFile.exists()) {
        await currentFile.delete();
      }
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (_) {
      // The original file and the legacy file remain available for recovery.
    }
  }

  bool _samePath(String first, String second) {
    return p.normalize(first).toLowerCase() ==
        p.normalize(second).toLowerCase();
  }
}
