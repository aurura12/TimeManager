import '../models/time_slot.dart';

class PendingGoogleDaySyncResult {
  final bool pullSucceeded;
  final bool? pushSucceeded;

  const PendingGoogleDaySyncResult({
    required this.pullSucceeded,
    required this.pushSucceeded,
  });
}

Future<PendingGoogleDaySyncResult> synchronizePendingGoogleDay({
  required Map<String, List<TimeSlot>> dailySlots,
  required String dateKey,
  required bool explicitlyPending,
  required List<TimeSlot> Function() createSlots,
  required Future<bool> Function() pull,
  required Future<bool> Function(List<TimeSlot> slots) push,
}) async {
  final hadLocalScheduleState = _hasLocalScheduleState(dailySlots[dateKey]);
  final pullSucceeded = await pull();
  final pulledSlots = dailySlots[dateKey];
  final hasLocalScheduleState = _hasLocalScheduleState(pulledSlots);

  if (!explicitlyPending && !hadLocalScheduleState && !hasLocalScheduleState) {
    return PendingGoogleDaySyncResult(
      pullSucceeded: pullSucceeded,
      pushSucceeded: null,
    );
  }

  final slotsForDay = dailySlots.putIfAbsent(dateKey, createSlots);
  final pushSucceeded = await push(slotsForDay);
  return PendingGoogleDaySyncResult(
    pullSucceeded: pullSucceeded,
    pushSucceeded: pushSucceeded,
  );
}

bool _hasLocalScheduleState(List<TimeSlot>? slots) {
  return slots?.any(
        (slot) =>
            !slot.isFromCalendar && (slot.deletedAt != null || slot.recorded),
      ) ??
      false;
}
