enum VoiceScheduleEventKind { existing, temporary }

enum VoiceScheduleConflictMode { fillEmptyOnly, replaceExisting }

class VoiceScheduleDraft {
  final DateTime date;
  final int startIndex;
  final int endIndexExclusive;
  final String label;
  final String? categoryId;
  final String transcript;
  final VoiceScheduleEventKind eventKind;

  const VoiceScheduleDraft({
    required this.date,
    required this.startIndex,
    required this.endIndexExclusive,
    required this.label,
    required this.categoryId,
    required this.transcript,
    required this.eventKind,
  });

  bool get isTemporary => eventKind == VoiceScheduleEventKind.temporary;
}

class VoiceScheduleParseResult {
  final VoiceScheduleDraft? draft;
  final String? error;

  const VoiceScheduleParseResult._({this.draft, this.error});

  const VoiceScheduleParseResult.success(VoiceScheduleDraft draft)
      : this._(draft: draft);

  const VoiceScheduleParseResult.failure(String error) : this._(error: error);

  bool get isSuccess => draft != null;
}

class VoiceScheduleApplyResult {
  final int appliedSlotCount;
  final int conflictCount;

  const VoiceScheduleApplyResult({
    required this.appliedSlotCount,
    required this.conflictCount,
  });
}
