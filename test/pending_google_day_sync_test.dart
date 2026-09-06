import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/services/pending_google_day_sync.dart';

List<TimeSlot> _emptyDay() {
  return List.generate(
    144,
    (index) => TimeSlot(hour: index ~/ 6, minute10: index % 6),
  );
}

void main() {
  test('push uses the day list inserted by pull instead of a temporary list',
      () async {
    const dateKey = '2026-08-23';
    final dailySlots = <String, List<TimeSlot>>{};
    final pulledSlots = _emptyDay();
    pulledSlots[42]
      ..recorded = true
      ..label = '工作';
    List<TimeSlot>? pushedSlots;

    final result = await synchronizePendingGoogleDay(
      dailySlots: dailySlots,
      dateKey: dateKey,
      explicitlyPending: true,
      createSlots: _emptyDay,
      pull: () async {
        dailySlots[dateKey] = pulledSlots;
        return true;
      },
      push: (slots) async {
        pushedSlots = slots;
        return true;
      },
    );

    expect(result.pushSucceeded, isTrue);
    expect(identical(pushedSlots, pulledSlots), isTrue);
  });

  test('calendar-only non-pending day does not trigger destructive push',
      () async {
    const dateKey = '2026-08-23';
    final dailySlots = <String, List<TimeSlot>>{};
    var pushCalls = 0;

    final result = await synchronizePendingGoogleDay(
      dailySlots: dailySlots,
      dateKey: dateKey,
      explicitlyPending: false,
      createSlots: _emptyDay,
      pull: () async {
        final slots = _emptyDay();
        slots[48]
          ..recorded = true
          ..label = '外部会议'
          ..isFromCalendar = true;
        dailySlots[dateKey] = slots;
        return true;
      },
      push: (_) async {
        pushCalls++;
        return true;
      },
    );

    expect(pushCalls, 0);
    expect(result.pushSucceeded, isNull);
  });

  test('explicitly pending empty day still pushes an intentional clear',
      () async {
    const dateKey = '2026-08-23';
    final dailySlots = <String, List<TimeSlot>>{};
    var pushCalls = 0;

    final result = await synchronizePendingGoogleDay(
      dailySlots: dailySlots,
      dateKey: dateKey,
      explicitlyPending: true,
      createSlots: _emptyDay,
      pull: () async => true,
      push: (slots) async {
        pushCalls++;
        expect(identical(slots, dailySlots[dateKey]), isTrue);
        return true;
      },
    );

    expect(pushCalls, 1);
    expect(result.pushSucceeded, isTrue);
  });

  test('tombstone authorizes push even when the date is not pending', () async {
    const dateKey = '2026-08-23';
    final slots = _emptyDay();
    slots[54].deletedAt = DateTime.fromMillisecondsSinceEpoch(1787443200123);
    final dailySlots = <String, List<TimeSlot>>{dateKey: slots};
    var pushCalls = 0;

    final result = await synchronizePendingGoogleDay(
      dailySlots: dailySlots,
      dateKey: dateKey,
      explicitlyPending: false,
      createSlots: _emptyDay,
      pull: () async => true,
      push: (_) async {
        pushCalls++;
        return true;
      },
    );

    expect(pushCalls, 1);
    expect(result.pushSucceeded, isTrue);
  });

  test('calendar tombstone does not authorize a non-pending Google push',
      () async {
    const dateKey = '2026-08-23';
    final slots = _emptyDay();
    slots[55]
      ..deletedAt = DateTime.fromMillisecondsSinceEpoch(1787443200123)
      ..isFromCalendar = true;
    final dailySlots = <String, List<TimeSlot>>{dateKey: slots};
    var pushCalls = 0;

    final result = await synchronizePendingGoogleDay(
      dailySlots: dailySlots,
      dateKey: dateKey,
      explicitlyPending: false,
      createSlots: _emptyDay,
      pull: () async => true,
      push: (_) async {
        pushCalls++;
        return true;
      },
    );

    expect(pushCalls, 0);
    expect(result.pushSucceeded, isNull);
  });

  test('pre-pull tombstone still authorizes push if pull replaces the slot',
      () async {
    const dateKey = '2026-08-23';
    final beforePull = _emptyDay();
    beforePull[60].deletedAt =
        DateTime.fromMillisecondsSinceEpoch(1787443200123);
    final afterPull = _emptyDay();
    afterPull[60]
      ..recorded = true
      ..label = '外部会议'
      ..isFromCalendar = true;
    final dailySlots = <String, List<TimeSlot>>{dateKey: beforePull};
    List<TimeSlot>? pushedSlots;

    final result = await synchronizePendingGoogleDay(
      dailySlots: dailySlots,
      dateKey: dateKey,
      explicitlyPending: false,
      createSlots: _emptyDay,
      pull: () async {
        dailySlots[dateKey] = afterPull;
        return true;
      },
      push: (slots) async {
        pushedSlots = slots;
        return true;
      },
    );

    expect(result.pushSucceeded, isTrue);
    expect(identical(pushedSlots, afterPull), isTrue);
  });

  test('continuation guard prevents slot creation after pull invalidation',
      () async {
    const dateKey = '2026-08-23';
    final dailySlots = <String, List<TimeSlot>>{};
    var canContinue = true;
    var pushCalls = 0;

    final result = await synchronizePendingGoogleDay(
      dailySlots: dailySlots,
      dateKey: dateKey,
      explicitlyPending: true,
      createSlots: _emptyDay,
      pull: () async {
        canContinue = false;
        return true;
      },
      canContinue: () => canContinue,
      push: (_) async {
        pushCalls++;
        return true;
      },
    );

    expect(result.pullSucceeded, isTrue);
    expect(result.pushSucceeded, isFalse);
    expect(pushCalls, 0);
    expect(dailySlots, isEmpty);
  });
}
