import 'dart:convert';

class ScheduleOverwriteSnapshotResult {
  final Map<String, List<Map<String, dynamic>>> entriesByDate;
  final String? error;

  const ScheduleOverwriteSnapshotResult.valid(this.entriesByDate)
      : error = null;
  const ScheduleOverwriteSnapshotResult.invalid(this.error)
      : entriesByDate = const {};

  bool get isValid => error == null;
}

class ScheduleOverwriteSnapshot {
  static String? dateKeyFromCanonicalPath(
    String path, {
    required String userCode,
  }) {
    if (userCode != 'g' && userCode != 'j') return null;
    final user = RegExp.escape(userCode);
    final match = RegExp('^schedule/$user/(\\d{4}-\\d{2}-\\d{2})\\.json\$')
        .firstMatch(path);
    if (match == null) return null;
    final date = match.group(1)!;
    final parts = date.split('-').map(int.parse).toList();
    final reconstructed = DateTime(parts[0], parts[1], parts[2]);
    if (reconstructed.year != parts[0] ||
        reconstructed.month != parts[1] ||
        reconstructed.day != parts[2]) {
      return null;
    }
    return date;
  }

  static bool isCanonicalSchedulePath(
    String path, {
    required String userCode,
  }) =>
      dateKeyFromCanonicalPath(path, userCode: userCode) != null;

  static ScheduleOverwriteSnapshotResult fromRemoteFiles({
    required String userCode,
    required Map<String, String> contentsByPath,
  }) {
    final entries = <String, List<Map<String, dynamic>>>{};
    for (final file in contentsByPath.entries) {
      final date = dateKeyFromCanonicalPath(file.key, userCode: userCode);
      if (date == null) continue;
      try {
        final decoded = jsonDecode(file.value);
        final slots = decoded is List
            ? decoded
            : decoded is Map && decoded['slots'] is List
                ? decoded['slots'] as List
                : throw const FormatException('slots must be a list');
        final day = <Map<String, dynamic>>[];
        final indexes = <int>{};
        for (final raw in slots) {
          if (raw is! Map) throw const FormatException('slot must be an object');
          final slot = Map<String, dynamic>.from(raw);
          final index = slot['i'];
          if (index is! int || index < 0 || index > 143 || !indexes.add(index)) {
            throw const FormatException('invalid slot index');
          }
          final deleted = slot['del'];
          for (final key in const ['fc', 'del']) {
            if (slot.containsKey(key) && slot[key] is! bool) {
              throw const FormatException('invalid boolean field');
            }
          }
          if (slot.containsKey('l') && slot['l'] is! String) {
            throw const FormatException('invalid label');
          }
          if (deleted != true &&
              (slot['l'] is! String || (slot['l'] as String).isEmpty)) {
            throw const FormatException('invalid label');
          }
          for (final key in const ['cid', 'eid']) {
            if (slot.containsKey(key) && slot[key] is! String) {
              throw const FormatException('invalid identifier');
            }
          }
          for (final key in const ['c', 'ts']) {
            if (slot.containsKey(key) && slot[key] is! num) {
              throw const FormatException('invalid numeric field');
            }
          }
          day.add(slot);
        }
        day.sort((a, b) => (a['i'] as int).compareTo(b['i'] as int));
        entries[date] = day;
      } catch (_) {
        return const ScheduleOverwriteSnapshotResult.invalid(
          'Invalid schedule snapshot',
        );
      }
    }
    return ScheduleOverwriteSnapshotResult.valid(entries);
  }
}
