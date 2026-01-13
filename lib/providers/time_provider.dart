import 'package:flutter/material.dart';
import '../models/time_slot.dart'; // 确保导入了模型
import '../models/category.dart';
import 'dart:convert';
import '../services/google_calendar_service.dart';

class TimeProvider with ChangeNotifier {
  DateTime _currentDate = DateTime.now();

  // 存储模型对象 Map
  final Map<String, List<TimeSlot>> _dailySlots = {};

  DateTime get currentDate => _currentDate;

  final Map<String, List<List<TimeSlot>>> _undoStacks = {};
  final int _maxStackSize = 20; // 最大支持撤回 20 步

  List<TimeSlot> get slots {
    String dateKey = _getDateKey(_currentDate);
    return _dailySlots.putIfAbsent(dateKey, () => _generateInitialSlots());
  }

  // 生成一天 144 个初始槽位对象
  List<TimeSlot> _generateInitialSlots() {
    return List.generate(144, (index) {
      int h = index ~/ 6;
      int m10 = index % 6;
      return TimeSlot(hour: h, minute10: m10, recorded: false);
    });
  }

  String _getDateKey(DateTime date) {
    return "${date.year}-${date.month}-${date.day}";
  }

  void previousDay() {
    _currentDate = _currentDate.subtract(const Duration(days: 1));
    notifyListeners();
  }

  void nextDay() {
    _currentDate = _currentDate.add(const Duration(days: 1));
    notifyListeners();
  }

  void toggleSlot(int index) {
    List<TimeSlot> currentSlots = slots;
    // 假设 TimeSlot 类有一个 recorded 属性，并且没有使用 final 修饰它
    // 或者你需要创建一个新的对象（取决于你的模型定义）
    currentSlots[index].recorded = !currentSlots[index].recorded;
    notifyListeners();
  }

  void clearAll() {
    _saveSnapshot(); // 修改前保存快照

    String dateKey = _getDateKey(_currentDate);
    _dailySlots[dateKey] = _generateInitialSlots();
    notifyListeners();
    _triggerAutoSync();
  }

  void _saveSnapshot() {
    String dateKey = _getDateKey(_currentDate);
    _undoStacks.putIfAbsent(dateKey, () => []);

    // 深度拷贝当前的 slots
    List<TimeSlot> snapshot = slots
        .map((s) => TimeSlot(
              hour: s.hour,
              minute10: s.minute10,
              recorded: s.recorded,
              label: s.label,
              color: s.color,
            ))
        .toList();

    _undoStacks[dateKey]!.add(snapshot);

    // 如果超过最大步数，移除最早的一条
    if (_undoStacks[dateKey]!.length > _maxStackSize) {
      _undoStacks[dateKey]!.removeAt(0);
    }
  }

  void undo() {
    String dateKey = _getDateKey(_currentDate);
    if (_undoStacks[dateKey] != null && _undoStacks[dateKey]!.isNotEmpty) {
      _dailySlots[dateKey] = _undoStacks[dateKey]!.removeLast();
      notifyListeners();
      _triggerAutoSync();
    }
  }

  void assignCategoryToSlots(Set<int> indices, Category category,
      {String? subLabel}) {
    if (indices.isEmpty) return; // 如果没有选中任何格子，不需要保存快照

    _saveSnapshot(); // 【关键】在循环修改数据之前保存当前状态

    for (var index in indices) {
      slots[index].recorded = true;
      slots[index].label = subLabel ?? category.name;
      slots[index].color = category.color;
    }
    notifyListeners();
    _triggerAutoSync();
  }

  // 触发自动同步
  void _triggerAutoSync() {
    if (GoogleCalendarService.currentUser != null) {
      GoogleCalendarService.syncSlotsToGoogle(slots, _currentDate);
    }
  }
}
