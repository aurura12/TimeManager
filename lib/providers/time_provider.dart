import 'package:flutter/material.dart';
import '../models/time_slot.dart'; // 确保导入了模型
import '../models/category.dart';
import 'dart:convert';
import '../services/google_calendar_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../models/target.dart';
import 'dart:async';
import 'package:fl_chart/fl_chart.dart';

class TimeProvider with ChangeNotifier {
  Timer? _debounceTimer;

  DateTime _currentDate = DateTime.now();
  bool _isSyncing = false; // 添加同步锁标志，防止并发同步导致重复

  // 存储模型对象 Map
  final Map<String, List<TimeSlot>> _dailySlots = {};

  // 目标列表移至 Provider 管理
  final List<Target> _targets = [];
  List<Target> get targets => _targets;

  // 分类列表移至 Provider 管理
  List<Category> _categories = [];
  List<Category> get categories => _categories;
  final int _startHour = 7; // 默认从 7 点开始
  int get startHour => _startHour;

  // 用于发送同步状态消息的 Stream
  final StreamController<String> _syncStatusController =
      StreamController<String>.broadcast();
  Stream<String> get syncStatusStream => _syncStatusController.stream;

  @override
  void dispose() {
    _debounceTimer?.cancel();
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

  void synchronizeWithGoogle() async {
    if (_isSyncing) return; // 如果正在同步，直接返回

    if (GoogleCalendarService.currentUser != null) {
      _isSyncing = true; // 加锁
      try {
        bool success =
            await GoogleCalendarService.syncSlotsToGoogle(slots, _currentDate);
        if (success) {
          _syncStatusController.add("同步成功");
        } else {
          _syncStatusController.add("同步失败，请稍后重试");
        }
      } finally {
        _isSyncing = false; // 无论成功失败，最后都要解锁
      }
    } else {
      _syncStatusController.add("未登录谷歌账号，无法同步");
    }
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
        'color': c.color.toARGB32(), // 修正：使用 .toARGB32() 替代已弃用的 .value
        'subCategories': c.subCategories,
      });
    }).toList();
    await prefs.setStringList('categories', catList);

    // 2. 保存目标 (新增)
    List<String> targetList =
        _targets.map((t) => json.encode(t.toJson())).toList();
    await prefs.setStringList('targets', targetList);

    // 3. 保存时间块
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
            'c': slots[i].color?.toARGB32(),
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

      // 确保存在“临时”分类，并添加到列表末尾
      if (!_categories.any((c) => c.name == '临时')) {
        _categories.add(Category(name: '临时', color: const Color(0xFF9E9E9E)));
      }
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
        Category(name: '临时', color: const Color(0xFF9E9E9E)),
      ];
    }

    // 2. 加载目标 (新增)
    List<String>? targetList = prefs.getStringList('targets');
    if (targetList != null) {
      _targets.clear();
      _targets.addAll(
          targetList.map((str) => Target.fromJson(json.decode(str))).toList());
    }

    // 3. 加载时间块
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
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    _debounceTimer = Timer(const Duration(milliseconds: 2000), () async {
      if (_isSyncing) return; // 如果正在同步，跳过本次自动同步

      if (GoogleCalendarService.currentUser != null) {
        _isSyncing = true; // 加锁
        try {
          // 先提示开始同步
          _syncStatusController.add("开始同步");
          await Future.delayed(const Duration(milliseconds: 500));
          if (_syncStatusController.isClosed) return;
          _syncStatusController.add("SYNCING");

          bool success = await GoogleCalendarService.syncSlotsToGoogle(
              slots, _currentDate);

          if (success) {
            _syncStatusController.add("同步成功");
            // 3秒后清空状态，让进度条消失
            Future.delayed(const Duration(seconds: 3),
                () => _syncStatusController.add("IDLE"));
          } else {
            _syncStatusController.add("同步失败");
            Future.delayed(const Duration(seconds: 3),
                () => _syncStatusController.add("IDLE"));
          }
        } finally {
          _isSyncing = false; // 解锁
        }
      }
    });
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

  void addTarget(Target target) {
    _targets.add(target);
    _saveData(); // 添加后保存
    notifyListeners();
  }

  void updateTarget(Target newTarget) {
    int index = _targets.indexWhere((t) => t.id == newTarget.id);
    if (index != -1) {
      _targets[index] = newTarget;
      _saveData(); // 更新后保存
      notifyListeners();
    }
  }

  void deleteTarget(Target target) {
    _targets.remove(target);
    _saveData(); // 删除后保存
    notifyListeners();
  }

  void reorderTargets(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final Target item = _targets.removeAt(oldIndex);
    _targets.insert(newIndex, item);
    _saveData();
    notifyListeners();
  }

  int getTargetPersistenceDays(Target target) {
    int count = 0;
    _dailySlots.forEach((_, daySlots) {
      // 1. 筛选出当天的相关事件
      var slots = daySlots.where((s) => s.recorded && s.label == target.name);

      if (slots.isNotEmpty) {
        // 如果是时间点目标，需要进行额外的时间区间和比较逻辑判断
        if (target.type == TargetType.timePoint) {
          // 2. 有效时间区间过滤 (如果设置了)
          if (target.startTime.isNotEmpty && target.endTime.isNotEmpty) {
            int startMins = _parseTime(target.startTime);
            int endMins = _parseTime(target.endTime);
            slots = slots.where((s) {
              int t = s.hour * 60 + s.minute10 * 10;
              return t >= startMins && t < endMins;
            });
          }

          if (slots.isNotEmpty) {
            // 3. 比较目标时间
            int targetMins = _parseTime(target.targetTime);
            // 取最早的一次记录作为比较对象
            int earliestMins = slots
                .map((s) => s.hour * 60 + s.minute10 * 10)
                .reduce((a, b) => a < b ? a : b);

            if (target.compareType.contains("前") ||
                target.compareType.contains("少")) {
              if (earliestMins <= targetMins) count++;
            } else {
              if (earliestMins >= targetMins) count++;
            }
          }
        } else {
          // 非时间点目标，只要有记录就算坚持了一天 (保持原有逻辑)
          count++;
        }
      }
    });
    return count;
  }

  // 获取目标的历史记录，合并连续时间块
  Map<String, List<String>> getTargetHistory(Target target) {
    Map<String, List<String>> history = {};

    // 1. 找出所有包含该目标记录的日期
    List<String> validDates = _dailySlots.keys.where((dateKey) {
      return _dailySlots[dateKey]!
          .any((s) => s.recorded && s.label == target.name);
    }).toList();

    // 2. 按日期倒序排列 (最新的在前面)
    validDates.sort((a, b) {
      List<String> partsA = a.split('-');
      List<String> partsB = b.split('-');
      DateTime dA = DateTime(
          int.parse(partsA[0]), int.parse(partsA[1]), int.parse(partsA[2]));
      DateTime dB = DateTime(
          int.parse(partsB[0]), int.parse(partsB[1]), int.parse(partsB[2]));
      return dB.compareTo(dA);
    });

    // 3. 生成时间段字符串
    for (String dateKey in validDates) {
      List<TimeSlot> daySlots = _dailySlots[dateKey]!;
      List<String> ranges = [];
      int? startIdx;
      int? endIdx;

      for (int i = 0; i < daySlots.length; i++) {
        bool isTarget =
            daySlots[i].recorded && daySlots[i].label == target.name;
        if (isTarget) {
          if (startIdx == null) startIdx = i;
          endIdx = i;
        } else {
          if (startIdx != null) {
            ranges.add(_formatRange(startIdx, endIdx!));
            startIdx = null;
            endIdx = null;
          }
        }
      }
      // 处理一天结束时的最后一段
      if (startIdx != null) {
        ranges.add(_formatRange(startIdx, endIdx!));
      }

      if (ranges.isNotEmpty) {
        List<String> parts = dateKey.split('-');
        String formattedDate =
            "${parts[0]}.${parts[1].padLeft(2, '0')}.${parts[2].padLeft(2, '0')}";
        history[formattedDate] = ranges;
      }
    }
    return history;
  }

  String _formatRange(int startIdx, int endIdx) {
    int startH = startIdx ~/ 6;
    int startM = (startIdx % 6) * 10;
    // endIdx 是闭区间，结束时间是 endIdx + 1 个格子的开始时间
    int endTotalIdx = endIdx + 1;
    int endH = endTotalIdx ~/ 6;
    int endM = (endTotalIdx % 6) * 10;

    String startStr =
        "${startH.toString().padLeft(2, '0')}:${startM.toString().padLeft(2, '0')}";
    String endStr =
        "${endH.toString().padLeft(2, '0')}:${endM.toString().padLeft(2, '0')}";
    // 特殊处理 24:00
    if (endH == 24 && endM == 0) endStr = "24:00";

    return "$startStr~$endStr";
  }

  int _parseTime(String time) {
    if (time.isEmpty) return 0;
    try {
      final parts = time.split(':');
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    } catch (_) {
      return 0;
    }
  }

  // 计算目标在当前周期内的进度
  double calculateTargetProgress(Target target) {
    DateTime now = DateTime.now();
    // 归一化到当天的 00:00:00
    DateTime startDate = DateTime(now.year, now.month, now.day);
    DateTime endDate = startDate.add(const Duration(days: 1));

    // 1. 确定统计的时间范围
    if (target.period == "每周" || target.period == "本周") {
      // 假设周一为一周开始
      startDate = startDate.subtract(Duration(days: startDate.weekday - 1));
      endDate = startDate.add(const Duration(days: 7));
    } else if (target.period == "每月" || target.period == "本月") {
      startDate = DateTime(now.year, now.month, 1);
      endDate = DateTime(now.year, now.month + 1, 1);
    } else if (target.period == "每年" || target.period == "今年") {
      startDate = DateTime(now.year, 1, 1);
      endDate = DateTime(now.year + 1, 1, 1);
    } else if (target.period.startsWith("每") &&
        target.period.endsWith("天") &&
        target.period != "每天") {
      try {
        final match = RegExp(r'每(\d+)天').firstMatch(target.period);
        if (match != null) {
          int periodDays = int.parse(match.group(1)!);
          DateTime createTime =
              DateTime.fromMillisecondsSinceEpoch(int.parse(target.id));
          DateTime startOfCreate =
              DateTime(createTime.year, createTime.month, createTime.day);
          int daysSince = startDate.difference(startOfCreate).inDays;
          if (daysSince >= 0) {
            int cycleIndex = daysSince ~/ periodDays;
            startDate =
                startOfCreate.add(Duration(days: cycleIndex * periodDays));
            endDate = startDate.add(Duration(days: periodDays));
          }
        }
      } catch (_) {}
    }

    double totalValue = 0.0;
    for (DateTime d = startDate;
        d.isBefore(endDate);
        d = d.add(const Duration(days: 1))) {
      String key = _getDateKey(d);
      if (_dailySlots.containsKey(key)) {
        List<TimeSlot> slots = _dailySlots[key]!;
        if (target.type == TargetType.duration) {
          totalValue +=
              slots.where((s) => s.recorded && s.label == target.name).length *
                  10.0 /
                  60.0;
        } else if (target.type == TargetType.frequency) {
          bool inBlock = false;
          for (var slot in slots) {
            bool isTarget = slot.recorded && slot.label == target.name;
            if (isTarget && !inBlock) {
              totalValue += 1;
              inBlock = true;
            } else if (!isTarget) {
              inBlock = false;
            }
          }
        }
      }
    }
    return totalValue;
  }

  Map<String, double> getStatistics(DateTime start, DateTime end) {
    Map<String, double> stats = {};

    // 遍历日期范围内的每一天
    for (int i = 0; i <= end.difference(start).inDays; i++) {
      DateTime date = start.add(Duration(days: i));
      String key = _getDateKey(date);

      if (_dailySlots.containsKey(key)) {
        for (var slot in _dailySlots[key]!) {
          if (slot.recorded && slot.label != null) {
            // 每个格子代表 1/6 小时 (10分钟)
            stats[slot.label!] = (stats[slot.label!] ?? 0) + (1 / 6);
          }
        }
      }
    }
    return stats;
  }
}
