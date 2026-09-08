import 'dart:convert';

import 'schedule_day_merge.dart';

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
        // 逐条校验规则与普通拉取/推送共享（见 scheduleDayEntriesError），
        // 保证"覆盖拉取认为非法"的记录在其他同步路径也一定被拒绝。
        final entryError = scheduleDayEntriesError(slots);
        if (entryError != null) {
          throw FormatException(entryError);
        }
        final day = <Map<String, dynamic>>[];
        for (final raw in slots) {
          day.add(Map<String, dynamic>.from(raw));
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
