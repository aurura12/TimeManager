import 'package:flutter/material.dart';

/// 时间块缩放（拖拽边界调整时长）的请求模型。
///
/// 网格里一个「块」是连续的一串 10 分钟槽位，所以调整时长本质上是把块的
/// 起点或终点挪到另一个槽位。UI 只负责给出目标边界，真正的定位与校验在
/// `TimeProvider.resizeTimeBlock` 里完成。
enum TimeSlotResizeEdge {
  /// 拖动块的起点（第一格）
  start,

  /// 拖动块的终点（最后一格）
  end,
}

/// 一次拖拽结束时提交的缩放请求。
class TimeSlotResizeRequest {
  const TimeSlotResizeRequest({
    required this.date,
    required this.anchorIndex,
    required this.edge,
    required this.targetIndex,
    required this.expectedStart,
    required this.expectedEnd,
    required this.expectedLabel,
    required this.expectedCategoryId,
    required this.expectedColor,
  });

  /// 块所在的自然日（桌面三列里可能是昨天 / 明天）
  final DateTime date;

  /// 被拖动的那条边在原始范围里的槽位索引，用于重新定位块
  final int anchorIndex;

  /// 拖的是起点还是终点
  final TimeSlotResizeEdge edge;

  /// 期望的新边界槽位（含）
  final int targetIndex;

  /// 手势开始时的完整逻辑块范围，用于发现拖拽期间被后台改写的数据
  final int expectedStart;
  final int expectedEnd;

  /// 手势开始时的块身份，与范围一起做 stale 校验
  final String expectedLabel;
  final String? expectedCategoryId;
  final Color expectedColor;
}
