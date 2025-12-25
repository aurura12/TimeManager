import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/time_slot.dart';

class TimeProvider with ChangeNotifier {
  List<TimeSlot> _slots = List.generate(144, (i) => TimeSlot(hour: i ~/ 6, minute10: (i % 6) * 10));

  List<TimeSlot> get slots => _slots;

  void togglePriority(int index) {
    int nextIndex = (_slots[index].priority.index + 1) % Priority.values.length;
    _slots[index].priority = Priority.values[nextIndex];
    notifyListeners();
  }

  // 统计每个优先级占用的分钟数
  Map<Priority, int> getStatistics() {
    Map<Priority, int> stats = {Priority.high: 0, Priority.medium: 0, Priority.low: 0};
    for (var slot in _slots) {
      if (slot.priority != Priority.none) {
        stats[slot.priority] = stats[slot.priority]! + 10;
      }
    }
    return stats;
  }

  // 导出为 JSON 字符串
  String exportData() => jsonEncode(_slots.map((s) => s.toJson()).toList());

  // 从 JSON 字符串导入
  void importData(String jsonString) {
    try {
      Iterable decoded = jsonDecode(jsonString);
      _slots = decoded.map((model) => TimeSlot.fromJson(model)).toList();
      notifyListeners();
    } catch (e) {
      debugPrint("导入失败: $e");
    }
  }
}