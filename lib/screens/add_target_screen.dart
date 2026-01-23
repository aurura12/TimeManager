import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/target.dart';

class AddTargetScreen extends StatefulWidget {
  const AddTargetScreen({super.key});

  @override
  State<AddTargetScreen> createState() => _AddTargetScreenState();
}

class _AddTargetScreenState extends State<AddTargetScreen> {
  TargetType _selectedType = TargetType.duration;
  int _selectedColorIndex = 0;
  String _selectedPeriod = "每周";

  // --- 可编辑的表单数据 ---
  String _eventName = "运动";
  String _compareType = "超过";
  String _durationValue = "6"; // 仅数字部分
  String _frequencyCount = "3";
  String _targetTime = "22:00";
  String _startTime = "16:00";
  String _endTime = "24:00";

  final List<Color> _themeColors = [
    const Color(0xFFF16B77),
    const Color(0xFFF98E45),
    const Color(0xFFD9BD2E),
    const Color(0xFF96B462),
    const Color(0xFF4DA8EE),
    const Color(0xFF9575CD),
    const Color(0xFFE91E63),
  ];

  // --- 辅助方法：显示输入弹窗 ---
  Future<void> _showInputDialog(
      String title, String currentValue, Function(String) onSave,
      {bool isNumber = false}) async {
    TextEditingController controller =
        TextEditingController(text: currentValue);
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("设置$title"),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: isNumber ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(hintText: "请输入$title"),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
            onPressed: () {
              if (controller.text.isEmpty) {
                // Show a message if the input is empty.
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入天数')),
                );
              } else {
                onSave(controller.text);
                Navigator.pop(context);
                setState(() {});
              }
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTime(String initialTime, Function(String) onSave) async {
    final parts = initialTime.split(':');
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: int.parse(parts[0]),
          minute: int.parse(parts[1] == "24" ? "0" : parts[1])),
    );
    if (picked != null) {
      setState(() {
        onSave(
            "${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}");
      });
    }
  }

  // --- 辅助方法：事件选择弹窗 ---
  void _showEventSelectionDialog() {
    final provider = Provider.of<TimeProvider>(context, listen: false);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("选择事件"),
          content: SizedBox(
            width: double.maxFinite,
            child: provider.categories.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text("暂无已有事件，请先在首页添加"),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: provider.categories.length,
                    itemBuilder: (context, index) {
                      final category = provider.categories[index];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor: category.color,
                              radius: 8,
                            ),
                            title: Text(category.name),
                            onTap: () {
                              setState(() => _eventName = category.name);
                              Navigator.pop(context);
                            },
                          ),
                          if (category.subCategories.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 56.0, bottom: 8.0),
                              child: Wrap(
                                spacing: 8.0,
                                runSpacing: 4.0,
                                children: category.subCategories.map((sub) {
                                  return ActionChip(
                                    label: Text(sub,
                                        style: const TextStyle(fontSize: 12)),
                                    backgroundColor:
                                        category.color.withValues(alpha: 0.2),
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      setState(() => _eventName = sub);
                                      Navigator.pop(context);
                                    },
                                  );
                                }).toList(),
                              ),
                            ),
                          const Divider(height: 1),
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    Color activeColor = _themeColors[_selectedColorIndex];

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF96B462),
        elevation: 0,
        leadingWidth: 80,
        leading: TextButton(
          onPressed: () {
            final provider = Provider.of<TimeProvider>(context, listen: false);
            final newTarget = Target(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: _eventName,
              type: _selectedType,
              color: activeColor,
              period: _selectedPeriod,
              compareType: _compareType,
              durationHours: double.tryParse(_durationValue) ?? 0,
              frequencyCount: int.tryParse(_frequencyCount) ?? 0,
              targetTime: _targetTime,
              startTime: _startTime,
              endTime: _endTime,
            );
            provider.addTarget(newTarget);
            Navigator.pop(context);
          },
          child: const Text("确定",
              style: TextStyle(color: Colors.white, fontSize: 16)),
        ),
        title: const Text("制定计划", style: TextStyle(color: Colors.white)),
        centerTitle: true,
        actions: [
          PopupMenuButton<TargetType>(
            initialValue: _selectedType,
            onSelected: (TargetType type) {
              setState(() {
                _selectedType = type;
                // 切换类型时自动调整默认比较词
                _compareType = (type == TargetType.timePoint) ? "之前" : "超过";
              });
            },
            child: Row(
              children: [
                Text(_getTypeName(_selectedType),
                    style: const TextStyle(color: Colors.white)),
                const Icon(Icons.arrow_drop_down, color: Colors.white),
                const SizedBox(width: 10),
              ],
            ),
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: TargetType.duration, child: Text("时长目标")),
              const PopupMenuItem(
                  value: TargetType.timePoint, child: Text("时间点目标")),
              const PopupMenuItem(
                  value: TargetType.frequency, child: Text("次数目标")),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 预览卡片
            _buildPreviewCard(activeColor),
            // 2. 颜色选择器
            _buildColorPicker(),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text("点击下方按钮制定计划",
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
            // 3. 周期选择
            if (_selectedType != TargetType.timePoint) ...[
              _buildSectionTitle("周期:"),
              _buildPeriodGrid(),
            ],
            const SizedBox(height: 20),
            _buildSectionTitle("计划内容:"),
            // 4. 表单内容
            _buildTargetContentForm(),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewCard(Color activeColor) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      width: double.infinity,
      decoration: BoxDecoration(
          color: activeColor, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selectedType != TargetType.timePoint)
            Text(_selectedPeriod,
                style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Text(_getPreviewText(),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildTargetContentForm() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        // 【关键修复】：显式设置内部列的所有组件从左侧开始排列
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFormRow("事件名称", _eventName, () => _showEventSelectionDialog()),
          _buildFormRow("比较类型", _compareType, () {
            List<String> types = ["超过", "少于", "等于"];
            int index = types.indexOf(_compareType);
            setState(() {
              _compareType = types[(index + 1) % types.length];
            });
          }),
          if (_selectedType == TargetType.duration)
            _buildFormRow(
                "事件时长",
                "$_durationValue小时",
                () => _showInputDialog(
                    "时长(小时)", _durationValue, (v) => _durationValue = v,
                    isNumber: true)),
          if (_selectedType == TargetType.frequency)
            _buildFormRow(
                "比较次数",
                _frequencyCount,
                () => _showInputDialog(
                    "次数", _frequencyCount, (v) => _frequencyCount = v,
                    isNumber: true)),
          if (_selectedType == TargetType.timePoint) ...[
            _buildFormRow("比较时间", _targetTime,
                () => _pickTime(_targetTime, (v) => _targetTime = v)),
            const SizedBox(height: 10),
            // 现在这个 Text 会受到上面 crossAxisAlignment.start 的影响而居左
            const Text("有效时间区间:",
                style: TextStyle(fontSize: 16, color: Colors.black87)),
            const SizedBox(height: 10),
            Row(
              // 同时也确保这个 Row 内部的按钮也是从左开始
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                _buildSmallBtn(_startTime,
                    () => _pickTime(_startTime, (v) => _startTime = v)),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text("~")),
                _buildSmallBtn(
                    _endTime, () => _pickTime(_endTime, (v) => _endTime = v)),
              ],
            )
          ]
        ],
      ),
    );
  }

  // --- 基础组件封装 ---

  Widget _buildFormRow(String label, String value, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
              width: 80,
              child:
                  Text(label, style: const TextStyle(color: Colors.black54))),
          _buildSmallBtn(value, onTap),
        ],
      ),
    );
  }

  Widget _buildSmallBtn(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
            color: const Color(0xFF96B462),
            borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  String _getPreviewText() {
    switch (_selectedType) {
      case TargetType.duration:
        return "$_eventName$_compareType$_durationValue小时";
      case TargetType.timePoint:
        return "$_targetTime$_compareType$_eventName";
      case TargetType.frequency:
        return "$_eventName$_compareType$_frequencyCount次";
    }
  }

  String _getTypeName(TargetType type) {
    switch (type) {
      case TargetType.duration:
        return "时长目标";
      case TargetType.timePoint:
        return "时间点目标";
      case TargetType.frequency:
        return "次数目标";
    }
  }

  Widget _buildSectionTitle(String title, {double padding = 16}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padding, vertical: 8),
      child: Text(title,
          style: const TextStyle(fontSize: 16, color: Colors.black87)),
    );
  }

  Widget _buildColorPicker() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(_themeColors.length, (index) {
          return GestureDetector(
            onTap: () => setState(() => _selectedColorIndex = index),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: _themeColors[index].withValues(alpha: 0.3),
              child: CircleAvatar(
                radius: 14,
                backgroundColor: _themeColors[index],
                child: _selectedColorIndex == index
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildPeriodGrid() {
    List<String> periods = [
      "每天",
      "每周",
      "每月",
      "每年",
      "每n天",
      "今天",
      "本周",
      "一周内",
      "本月",
      "一月内",
      "今年",
      "一年内",
      "n天内",
      "起止日期"
    ];
    return Padding(
      // ----- 弹窗输入天数 -----
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: periods
            .map((p) => ChoiceChip(
                  label: Text(p),
                  selected: _selectedPeriod == p,
                  onSelected: (val) {
                    if (p == "每n天" || p == "n天内") {
                      _showInputDialog("天数", _durationValue, (v) {
                        setState(() {
                          _selectedPeriod = p.replaceAll('n', v);
                          _durationValue = v;
                        });
                      }, isNumber: true);
                    } else {
                      setState(() => _selectedPeriod = p);
                    }
                  },
                ))
            .toList(),
      ),
    );
  }
}
