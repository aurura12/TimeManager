import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/utils/time_slot_segment.dart';

void main() {
  test('same label with different colors is not rendered as one segment', () {
    final first = TimeSlot(
      hour: 9,
      minute10: 0,
      recorded: true,
      label: '工作',
      color: Colors.blue,
    );
    final second = TimeSlot(
      hour: 9,
      minute10: 1,
      recorded: true,
      label: '工作',
      color: Colors.red,
    );

    expect(canJoinTimeSlots(first, second), isFalse);
  });
}
