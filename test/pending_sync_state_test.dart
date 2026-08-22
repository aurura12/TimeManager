import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/pending_sync_state.dart';

void main() {
  test('legacy pending dates migrate to both services on Android', () {
    final state = PendingSyncState.fromLegacy(
      ['2026-08-21', '2026-08-22'],
      desktop: false,
    );

    expect(state.giteeDates, {'2026-08-21', '2026-08-22'});
    expect(state.googleDates, {'2026-08-21', '2026-08-22'});
  });

  test('legacy pending dates migrate only to Gitee on desktop', () {
    final state = PendingSyncState.fromLegacy(
      ['2026-08-22'],
      desktop: true,
    );

    expect(state.giteeDates, {'2026-08-22'});
    expect(state.googleDates, isEmpty);
  });

  test('clearing one service keeps the other service pending', () {
    final state = PendingSyncState(
      giteeDates: ['2026-08-22'],
      googleDates: ['2026-08-22'],
    );

    state.clearGitee('2026-08-22');

    expect(state.giteeDates, isEmpty);
    expect(state.googleDates, {'2026-08-22'});
    expect(state.visibleDates(googleEnabled: true), {'2026-08-22'});
    expect(state.visibleDates(googleEnabled: false), isEmpty);

    state.clearGoogle('2026-08-22');

    expect(state.visibleDates(googleEnabled: true), isEmpty);
  });

  test('prioritizes current date without dropping other pending dates', () {
    final ordered = PendingSyncState.orderDates(
      ['2026-08-20', '2026-08-22', '2026-08-21'],
      priorityDate: '2026-08-21',
    );

    expect(ordered, ['2026-08-21', '2026-08-20', '2026-08-22']);
  });
}
