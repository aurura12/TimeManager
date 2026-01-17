import 'package:flutter/material.dart';
import '../models/time_slot.dart'; // 确保导入了模型
import '../models/category.dart';
import 'dart:convert';
import '../services/google_calendar_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class TimeProvider with ChangeNotifier {
  DateTime _currentDate = DateTime.now();

  // 存储模型对象 Map
  final Map<String, List<TimeSlot>> _dailySlots = {};

  // 分类列表移至 Provider 管理
  List<Category> _categories = [];
  List<Category> get categories => _categories;
  int _startHour = 7; // 默认从 7 点开始
  int get startHour => _startHour;

  // 用于发送同步状态消息的 Stream
  final StreamController<String> _syncStatusController =
      StreamController<String>.broadcast();
  Stream<String> get syncStatusStream => _syncStatusController.stream;

  @override
  void dispose() {
    _syncStatusController.close();
    super.dispose();
  }

  TimeProvider() {
    _init();
  }

  Future<void> _init() async {
    // 1. 恢复谷歌登录状态
    await GoogleCalendarService.restoreSignIn();
    // 2. 加载本地数据
    await _loadData();
    notifyListeners();
  }

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
    // 切换日期不需要保存，因为数据都在 _dailySlots 里
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
    _saveData(); // 保存更改
    notifyListeners();
  }

  void clearAll() {
    _saveSnapshot(); // 修改前保存快照

    String dateKey = _getDateKey(_currentDate);
    _dailySlots[dateKey] = _generateInitialSlots();
    _saveData(); // 保存更改
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
      _saveData(); // 撤销后保存
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
    _saveData(); // 保存更改
    notifyListeners();
    _triggerAutoSync();
  }

  // 移除指定时间块的事件
  void removeEventFromSlot(int index) {
    if (index >= 0 && index < slots.length) {
      // 只有当该时间块确实有记录时才执行删除和保存快照
      if (slots[index].recorded) {
        _saveSnapshot();
        slots[index].recorded = false;
        slots[index].label = null;
        slots[index].color = null;
        _saveData();
        notifyListeners();
        _triggerAutoSync();
      }
    }
  }

  // --- 分类管理方法 (从 HomeScreen 移入) ---

  void addCategory(Category category) {
    _categories.add(category);
    _saveData();
    notifyListeners();
  }

  void updateCategory(int index, Category newCategory) {
    if (index >= 0 && index < _categories.length) {
      _categories[index] = newCategory;
      _saveData();
      notifyListeners();
    }
  }

  // --- 数据持久化逻辑 ---

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. 保存分类
    // 将 Category 对象转换为 JSON 列表
    List<String> catList = _categories.map((c) {
      return json.encode({
        'name': c.name,
        'color': c.color.value, // 保存颜色整数值
        'subCategories': c.subCategories,
      });
    }).toList();
    await prefs.setStringList('categories', catList);

    // 2. 保存时间块
    // 为了节省空间，只保存已记录(recorded=true)的块
    Map<String, dynamic> slotsJson = {};
    _dailySlots.forEach((dateKey, slots) {
      // 筛选出有数据的格子进行保存
      List<Map<String, dynamic>> recordedSlots = [];
      for (int i = 0; i < slots.length; i++) {
        if (slots[i].recorded) {
          recordedSlots.add({
            'i': i, // 索引
            'l': slots[i].label,
            'c': slots[i].color?.value,
          });
        }
      }
      if (recordedSlots.isNotEmpty) {
        slotsJson[dateKey] = recordedSlots;
      }
    });
    await prefs.setString('daily_slots', json.encode(slotsJson));
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. 加载分类
    List<String>? catList = prefs.getStringList('categories');
    if (catList != null && catList.isNotEmpty) {
      _categories = catList.map((str) {
        Map<String, dynamic> map = json.decode(str);
        return Category(
          name: map['name'],
          color: Color(map['color']),
          subCategories: List<String>.from(map['subCategories'] ?? []),
        );
      }).toList();
    } else {
      // 默认分类
      _categories = [
        Category(
            name: '学习',
            color: const Color(0xFFD4AF37),
            subCategories: ['阅读', '编程']),
        Category(
            name: '工作',
            color: const Color(0xFF9CB86A),
            subCategories: ['会议', '文档']),
        Category(name: '运动', color: const Color(0xFF4A90E2)),
      ];
    }

    // 2. 加载时间块
    String? slotsStr = prefs.getString('daily_slots');
    if (slotsStr != null) {
      try {
        Map<String, dynamic> slotsJson = json.decode(slotsStr);
        slotsJson.forEach((dateKey, value) {
          // 先生成当天的空白数据
          List<TimeSlot> daySlots = _generateInitialSlots();
          List<dynamic> recordedList = value;

          // 填充已保存的数据
          for (var item in recordedList) {
            int idx = item['i'];
            if (idx >= 0 && idx < daySlots.length) {
              daySlots[idx].recorded = true;
              daySlots[idx].label = item['l'];
              if (item['c'] != null) {
                daySlots[idx].color = Color(item['c']);
              }
            }
          }
          _dailySlots[dateKey] = daySlots;
        });
      } catch (e) {
        debugPrint("加载时间块数据出错: $e");
      }
    }
  }

  // 触发自动同步
  Future<void> _triggerAutoSync() async {
    if (GoogleCalendarService.currentUser != null) {
      bool success =
          await GoogleCalendarService.syncSlotsToGoogle(slots, _currentDate);
      if (success) {
        _syncStatusController.add("同步成功");
      }
    }
  }

  void reorderCategories(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final Category item = categories.removeAt(oldIndex);
    categories.insert(newIndex, item);

    // 通知 UI 更新并保存到本地存储
    notifyListeners();
    _saveData(); // 假设你有这个持久化方法
  }

  void deleteCategory(int index) {
    categories.removeAt(index);
    notifyListeners();
    _saveData(); // 确保保存更改
  }
}
