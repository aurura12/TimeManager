/// Tracks pending dates independently for each remote sync service.
class PendingSyncState {
  PendingSyncState({
    Iterable<String> giteeDates = const <String>[],
    Iterable<String> googleDates = const <String>[],
  })  : _giteeDates = {...giteeDates},
        _googleDates = {...googleDates};

  factory PendingSyncState.fromLegacy(
    Iterable<String> dates, {
    required bool desktop,
  }) {
    return PendingSyncState(
      giteeDates: dates,
      googleDates: desktop ? const <String>[] : dates,
    );
  }

  final Set<String> _giteeDates;
  final Set<String> _googleDates;

  Set<String> get giteeDates => Set.unmodifiable(_giteeDates);

  Set<String> get googleDates => Set.unmodifiable(_googleDates);

  Set<String> visibleDates({required bool googleEnabled}) => {
        ..._giteeDates,
        if (googleEnabled) ..._googleDates,
      };

  Set<String> get allDates => {..._giteeDates, ..._googleDates};

  void markGitee(String dateKey) => _giteeDates.add(dateKey);

  void markGoogle(String dateKey) => _googleDates.add(dateKey);

  void clearGitee(String dateKey) => _giteeDates.remove(dateKey);

  void clearGoogle(String dateKey) => _googleDates.remove(dateKey);

  void replace({
    Iterable<String> giteeDates = const <String>[],
    Iterable<String> googleDates = const <String>[],
  }) {
    _giteeDates
      ..clear()
      ..addAll(giteeDates);
    _googleDates
      ..clear()
      ..addAll(googleDates);
  }

  static List<String> orderDates(
    Iterable<String> dates, {
    String? priorityDate,
  }) {
    final ordered = dates.toSet().toList()..sort();
    if (priorityDate != null && ordered.remove(priorityDate)) {
      ordered.insert(0, priorityDate);
    }
    return ordered;
  }
}
