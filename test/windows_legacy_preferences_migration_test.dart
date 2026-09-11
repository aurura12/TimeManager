import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:time_manager/services/windows_legacy_preferences_migration.dart';

void main() {
  test('migrates legacy Windows preferences once without overwriting new data',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'time_manager_legacy_migration_',
    );
    addTearDown(() => root.delete(recursive: true));

    final currentDirectory = Directory(
      p.join(root.path, 'com.example', '\u65f6\u95f4\u5757'),
    );
    final legacyFile = File(
      p.join(
        root.path,
        'com.example',
        'time_manager',
        'shared_preferences.json',
      ),
    );
    final currentFile = File(
      p.join(
        currentDirectory.path,
        'shared_preferences.json',
      ),
    );

    final legacyContents = jsonEncode(<String, Object>{
      'flutter.daily_slots': '{"2026-09-11":[{"i":1,"l":"legacy schedule"}]}',
      'flutter.categories': <String>['legacy category'],
      'flutter.targets': <String>['legacy target'],
    });
    await _write(legacyFile, legacyContents);
    await _write(
      currentFile,
      jsonEncode(<String, Object>{
        'flutter.daily_slots': '{"2026-09-12":[{"i":2,"l":"new schedule"}]}',
        'flutter.targets': <String>['new target'],
        'flutter.travel_records_draft': 'new travel draft',
      }),
    );

    final migration = WindowsLegacyPreferencesMigration(
      isWindows: true,
      applicationSupportDirectoryProvider: () async => currentDirectory,
    );

    final first = await migration.migrate();

    expect(first.status, WindowsLegacyMigrationStatus.migrated);
    final migrated = await _read(currentFile);
    expect(
      migrated['flutter.daily_slots'],
      allOf(contains('legacy schedule'), contains('new schedule')),
    );
    expect(migrated['flutter.categories'], <dynamic>['legacy category']);
    expect(migrated['flutter.targets'], <dynamic>['new target']);
    expect(migrated['flutter.travel_records_draft'], 'new travel draft');
    expect(
      migrated[WindowsLegacyPreferencesMigration.migrationMarkerKey],
      isTrue,
    );
    expect(await legacyFile.readAsString(), legacyContents);

    final second = await migration.migrate();

    expect(second.status, WindowsLegacyMigrationStatus.alreadyMigrated);
    expect(await legacyFile.readAsString(), legacyContents);
  });

  test('skips migration on non-Windows platforms', () async {
    final root = await Directory.systemTemp.createTemp(
      'time_manager_legacy_migration_skip_',
    );
    addTearDown(() => root.delete(recursive: true));

    final currentDirectory = Directory(
      p.join(root.path, 'com.example', '\u65f6\u95f4\u5757'),
    );
    final legacyFile = File(
      p.join(
        root.path,
        'com.example',
        'time_manager',
        'shared_preferences.json',
      ),
    );
    await _write(
      legacyFile,
      jsonEncode(<String, Object>{
        'flutter.daily_slots': 'legacy schedule',
      }),
    );

    final migration = WindowsLegacyPreferencesMigration(
      isWindows: false,
      applicationSupportDirectoryProvider: () async => currentDirectory,
    );

    final result = await migration.migrate();

    expect(result.status, WindowsLegacyMigrationStatus.skippedNonWindows);
    expect(await currentDirectory.exists(), isFalse);
  });
}

Future<void> _write(File file, String contents) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

Future<Map<String, dynamic>> _read(File file) async {
  final decoded = jsonDecode(await file.readAsString());
  return Map<String, dynamic>.from(decoded as Map);
}
