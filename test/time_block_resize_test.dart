import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/time_slot.dart';
import 'package:time_manager/models/time_slot_resize.dart';
import 'package:time_manager/utils/time_block_resize.dart';

const _focus = Color(0xFF9CB86A);
const _rest = Color(0xFF5B8DEF);

List<TimeSlot> _emptyDay() => [
      for (var hour = 0; hour < 24; hour++)
        for (var minute = 0; minute < 6; minute++)
          TimeSlot(hour: hour, minute10: minute),
    ];

void _paint(List<TimeSlot> slots, int start, int end,
    {String label = '读书',
    String? categoryId = 'cat-focus',
    Color color = _focus,
    bool isFromCalendar = false}) {
  for (var index = start; index <= end; index++) {
    slots[index]
      ..recorded = true
      ..label = label
      ..categoryId = categoryId
      ..color = color
      ..isFromCalendar = isFromCalendar;
  }
}

void main() {
  group('findTimeBlockRange', () {
    test('相邻同标签槽位合并成一个块，可跨小时', () {
      final slots = _emptyDay();
      _paint(slots, 4, 9); // 00:40 - 01:30，跨 00 / 01 两行

      expect(findTimeBlockRange(slots, 4), const TimeBlockRange(4, 9));
      expect(findTimeBlockRange(slots, 7), const TimeBlockRange(4, 9));
      expect(findTimeBlockRange(slots, 9), const TimeBlockRange(4, 9));
      expect(findTimeBlockRange(slots, 7)!.length, 6);
    });

    test('事件名或颜色不同处断开', () {
      final slots = _emptyDay();
      _paint(slots, 10, 12);
      _paint(slots, 13, 15, label: '写作');
      _paint(slots, 16, 17, color: _rest);

      expect(findTimeBlockRange(slots, 11), const TimeBlockRange(10, 12));
      expect(findTimeBlockRange(slots, 14), const TimeBlockRange(13, 15));
      expect(findTimeBlockRange(slots, 16), const TimeBlockRange(16, 17));
    });

    test('日历块不会与本地块合并', () {
      final slots = _emptyDay();
      _paint(slots, 20, 21, isFromCalendar: true);
      _paint(slots, 22, 23);

      expect(findTimeBlockRange(slots, 20), const TimeBlockRange(20, 21));
      expect(findTimeBlockRange(slots, 22), const TimeBlockRange(22, 23));
    });

    test('空槽与无颜色槽位返回 null', () {
      final slots = _emptyDay();
      expect(findTimeBlockRange(slots, 0), isNull);

      slots[0]
        ..recorded = true
        ..label = '脏数据';
      expect(findTimeBlockRange(slots, 0), isNull);
    });

    test('越界索引返回 null', () {
      final slots = _emptyDay();
      _paint(slots, 0, 0);
      expect(findTimeBlockRange(slots, -1), isNull);
      expect(findTimeBlockRange(slots, 144), isNull);
    });

    test('首尾边界不会越界扫描', () {
      final slots = _emptyDay();
      _paint(slots, 0, 5);
      _paint(slots, 138, 143, label: '收尾');

      expect(findTimeBlockRange(slots, 0), const TimeBlockRange(0, 5));
      expect(findTimeBlockRange(slots, 143), const TimeBlockRange(138, 143));
    });
  });

  group('clampTimeBlockResizeTarget', () {
    test('起点不能越过终点，至少保留 1 格', () {
      expect(
        clampTimeBlockResizeTarget(
          edge: TimeSlotResizeEdge.start,
          originalStart: 10,
          originalEnd: 14,
          targetIndex: 20,
        ),
        14,
      );
      expect(
        clampTimeBlockResizeTarget(
          edge: TimeSlotResizeEdge.start,
          originalStart: 10,
          originalEnd: 14,
          targetIndex: 12,
        ),
        12,
      );
    });

    test('终点不能越过起点', () {
      expect(
        clampTimeBlockResizeTarget(
          edge: TimeSlotResizeEdge.end,
          originalStart: 10,
          originalEnd: 14,
          targetIndex: 2,
        ),
        10,
      );
    });

    test('夹在当天槽位范围内', () {
      expect(
        clampTimeBlockResizeTarget(
          edge: TimeSlotResizeEdge.start,
          originalStart: 10,
          originalEnd: 14,
          targetIndex: -5,
        ),
        0,
      );
      expect(
        clampTimeBlockResizeTarget(
          edge: TimeSlotResizeEdge.end,
          originalStart: 10,
          originalEnd: 14,
          targetIndex: 500,
        ),
        143,
      );
    });
  });

  group('applyTimeBlockResizePreview', () {
    test('拉长时新范围内的相邻记录被覆盖', () {
      final slots = _emptyDay();
      _paint(slots, 10, 11);
      _paint(slots, 12, 13, label: '写作', color: _rest);

      final preview = applyTimeBlockResizePreview(
        slots: slots,
        originalStart: 10,
        originalEnd: 11,
        newStart: 10,
        newEnd: 13,
        label: '读书',
        categoryId: 'cat-focus',
        color: _focus,
      );

      for (var index = 10; index <= 13; index++) {
        expect(preview[index].label, '读书');
        expect(preview[index].categoryId, 'cat-focus');
        expect(preview[index].color, _focus);
      }
      // 原数据不被修改
      expect(slots[12].label, '写作');
      expect(slots[13].label, '写作');
    });

    test('缩短时被裁掉的端变成空槽', () {
      final slots = _emptyDay();
      _paint(slots, 10, 13);

      final preview = applyTimeBlockResizePreview(
        slots: slots,
        originalStart: 10,
        originalEnd: 13,
        newStart: 12,
        newEnd: 13,
        label: '读书',
        categoryId: 'cat-focus',
        color: _focus,
      );

      expect(preview[10].recorded, isFalse);
      expect(preview[10].label, isNull);
      expect(preview[10].color, isNull);
      expect(preview[11].recorded, isFalse);
      expect(preview[12].label, '读书');
      expect(preview[13].label, '读书');
      expect(slots[10].recorded, isTrue);
    });

    test('范围没有变化时返回原列表', () {
      final slots = _emptyDay();
      _paint(slots, 10, 11);

      final preview = applyTimeBlockResizePreview(
        slots: slots,
        originalStart: 10,
        originalEnd: 11,
        newStart: 10,
        newEnd: 11,
        label: '读书',
        categoryId: 'cat-focus',
        color: _focus,
      );

      expect(identical(preview, slots), isTrue);
    });
  });
}
