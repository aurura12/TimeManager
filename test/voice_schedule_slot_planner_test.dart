import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/models/voice_schedule_draft.dart';
import 'package:time_manager/services/voice_schedule_slot_planner.dart';

void main() {
  final draft = VoiceScheduleDraft(
    date: DateTime(2026, 8, 19),
    startIndex: 90,
    endIndexExclusive: 96,
    label: '开会',
    categoryId: 'work',
    transcript: '下午三点到四点开会',
    eventKind: VoiceScheduleEventKind.existing,
  );

  test('仅填充空白时保留冲突槽位', () {
    final slots = List.generate(
        144, (index) => TimeSlot(hour: index ~/ 6, minute10: index % 6));
    slots[91].recorded = true;

    final plan = VoiceScheduleSlotPlanner.plan(
      slots: slots,
      draft: draft,
      mode: VoiceScheduleConflictMode.fillEmptyOnly,
    );

    expect(plan.conflictCount, 1);
    expect(plan.indicesToApply, {90, 92, 93, 94, 95});
  });

  test('覆盖冲突时返回整个语音日程范围', () {
    final slots = List.generate(
        144, (index) => TimeSlot(hour: index ~/ 6, minute10: index % 6));
    slots[91].recorded = true;

    final plan = VoiceScheduleSlotPlanner.plan(
      slots: slots,
      draft: draft,
      mode: VoiceScheduleConflictMode.replaceExisting,
    );

    expect(plan.conflictCount, 1);
    expect(plan.indicesToApply, {90, 91, 92, 93, 94, 95});
  });
}
