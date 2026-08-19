import '../models/time_slot.dart';
import '../models/voice_schedule_draft.dart';

class VoiceScheduleSlotPlan {
  final Set<int> indicesToApply;
  final int conflictCount;

  const VoiceScheduleSlotPlan({
    required this.indicesToApply,
    required this.conflictCount,
  });
}

class VoiceScheduleSlotPlanner {
  static VoiceScheduleSlotPlan plan({
    required List<TimeSlot> slots,
    required VoiceScheduleDraft draft,
    required VoiceScheduleConflictMode mode,
  }) {
    final range = <int>{};
    var conflictCount = 0;
    for (var index = draft.startIndex;
        index < draft.endIndexExclusive && index < slots.length;
        index++) {
      if (index < 0) continue;
      final isOccupied = slots[index].recorded;
      if (isOccupied) conflictCount++;
      if (mode == VoiceScheduleConflictMode.replaceExisting || !isOccupied) {
        range.add(index);
      }
    }
    return VoiceScheduleSlotPlan(
      indicesToApply: Set.unmodifiable(range),
      conflictCount: conflictCount,
    );
  }
}
