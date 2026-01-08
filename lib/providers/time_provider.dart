import 'package:flutter/material.dart';
import '../models/time_slot.dart'; // 确保导入了模型
import '../models/category.dart';

class TimeProvider with ChangeNotifier {
  DateTime _currentDate = DateTime.now();

  // 存储模型对象 Map
  final Map<String, List<TimeSlot>> _dailySlots = {};

  DateTime get currentDate => _currentDate;

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
    String dateKey = _getDateKey(_currentDate);
    _dailySlots[dateKey] = _generateInitialSlots();
    notifyListeners();
  }

  void undo() {
    // 暂留逻辑
  }

  void assignCategoryToSlots(Set<int> indices, Category category,
      {String? subLabel}) {
    for (var index in indices) {
      slots[index].recorded = true;
      slots[index].label = subLabel ?? category.name;
      slots[index].color = category.color;
    }
    notifyListeners();
  }
}
