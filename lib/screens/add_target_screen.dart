import 'package:flutter/material.dart';

class AddTargetScreen extends StatefulWidget {
  @override
  _AddTargetScreenState createState() => _AddTargetScreenState();
}

class _AddTargetScreenState extends State<AddTargetScreen> {
  String selectedPeriod = "每周";
  Color selectedColor = const Color(0xFFF16B77); // 默认红色

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('添加目标',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        centerTitle: true,
        backgroundColor: selectedColor,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: () {
              // TODO: 实现保存逻辑
              Navigator.pop(context);
            },
            child: const Text("保存",
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 目标名称输入
            const Text("目标名称",
                style: TextStyle(color: Colors.grey, fontSize: 14)),
            const TextField(
              decoration: InputDecoration(
                hintText: "例如：运动超过6小时",
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey)),
              ),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 30),

            // 周期选择
            const Text("周期",
                style: TextStyle(color: Colors.grey, fontSize: 14)),
            const SizedBox(height: 10),
            Row(
              children: ["每天", "每周", "每月"].map((period) {
                bool isSelected = selectedPeriod == period;
                return GestureDetector(
                  onTap: () => setState(() => selectedPeriod = period),
                  child: Container(
                    margin: const EdgeInsets.only(right: 12),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? selectedColor : Colors.grey[200],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      period,
                      style: TextStyle(
                          color: isSelected ? Colors.white : Colors.black87),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 30),

            // 颜色选择 (对应你主页的三个颜色)
            const Text("主题颜色",
                style: TextStyle(color: Colors.grey, fontSize: 14)),
            const SizedBox(height: 10),
            Row(
              children: [
                const Color(0xFFF16B77),
                const Color(0xFFF98E45),
                const Color(0xFFD9BD2E),
                const Color(0xFF96B462),
              ].map((color) {
                bool isSelected = selectedColor == color;
                return GestureDetector(
                  onTap: () => setState(() => selectedColor = color),
                  child: Container(
                    margin: const EdgeInsets.only(right: 15),
                    width: 35,
                    height: 35,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: isSelected
                          ? Border.all(color: Colors.black, width: 2)
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 30),

            // 目标数值设定 (简单示例)
            _buildSettingTile(Icons.flag_outlined, "目标数值", "6 小时"),
            _buildSettingTile(Icons.notifications_none, "提醒时间", "无"),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingTile(IconData icon, String title, String value) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: Colors.grey),
      title: Text(title),
      trailing: Text(value, style: const TextStyle(color: Colors.grey)),
      onTap: () {},
    );
  }
}
