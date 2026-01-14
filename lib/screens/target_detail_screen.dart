import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';

class TargetDetailScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      // 使用黑色状态栏文字
      appBar: AppBar(
        backgroundColor: const Color(0xFFF16B77),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.edit, color: Colors.white),
              onPressed: () {}),
          IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white),
              onPressed: () {}),
        ],
      ),
      body: Consumer<TimeProvider>(
        builder: (context, timeProvider, child) {
          final recordedSlots =
              timeProvider.slots.where((s) => s.recorded).toList();
          final totalMinutes = recordedSlots.length * 10;
          final double hours = totalMinutes / 60.0;

          return SingleChildScrollView(
            child: Column(
              children: [
                // 1. 顶部红色区域
                Container(
                  width: double.infinity,
                  color: const Color(0xFFF16B77),
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("每周",
                          style:
                              TextStyle(color: Colors.white70, fontSize: 16)),
                      const SizedBox(height: 8),
                      const Text(
                        "运动超过6小时",
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),

                // 2. 白色统计卡片 (重叠效果)
                Transform.translate(
                  offset: const Offset(0, -20),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black12,
                            blurRadius: 10,
                            offset: Offset(0, 5)),
                      ],
                    ),
                    child: Column(
                      children: [
                        _buildStatRow("已完成", "${hours.toStringAsFixed(1)} 小时"),
                        const Divider(height: 30),
                        _buildStatRow("完成度",
                            "${(hours / 6.0 * 100).toStringAsFixed(1)}%"),
                        const Divider(height: 30),
                        _buildStatRow("剩余",
                            "${(6.0 - hours).clamp(0, 6).toStringAsFixed(1)} 小时"),
                      ],
                    ),
                  ),
                ),

                // 3. 底部记录列表 (展示具体的片段)
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("历史记录",
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      ...recordedSlots.map((slot) {
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.access_time,
                              color: Color(0xFFF16B77)),
                          title: Text(
                              "${slot.hour}:${(slot.minute10 * 10).toString().padLeft(2, '0')}"),
                          trailing: const Text("+10 分钟",
                              style: TextStyle(color: Colors.grey)),
                        );
                      }).toList(),
                      if (recordedSlots.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text("暂无运动记录",
                              style: TextStyle(color: Colors.grey)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 16, color: Colors.black87)),
        Text(value,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF16B77))),
      ],
    );
  }
}
