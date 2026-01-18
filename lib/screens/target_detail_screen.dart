import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/target.dart';

class TargetDetailScreen extends StatelessWidget {
  final Target target;

  const TargetDetailScreen({super.key, required this.target});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      // 使用黑色状态栏文字
      appBar: AppBar(
        backgroundColor: target.color,
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
              onPressed: () {
                Provider.of<TimeProvider>(context, listen: false)
                    .deleteTarget(target);
                Navigator.pop(context);
              }),
        ],
      ),
      body: Consumer<TimeProvider>(
        builder: (context, timeProvider, child) {
          final recordedSlots = timeProvider.slots
              .where((s) => s.recorded && s.label == target.name)
              .toList();
          final totalMinutes = recordedSlots.length * 10;
          final double hours = totalMinutes / 60.0;
          final double targetHours = target.durationHours;

          return SingleChildScrollView(
            child: Column(
              children: [
                // 1. 顶部红色区域
                Container(
                  width: double.infinity,
                  color: target.color,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(target.period,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 16)),
                      const SizedBox(height: 8),
                      Text(
                        "${target.name}${target.compareType}${target.durationHours}小时",
                        style: const TextStyle(
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
                        _buildStatRow("已完成", "${hours.toStringAsFixed(1)} 小时",
                            target.color),
                        const Divider(height: 30),
                        _buildStatRow(
                            "完成度",
                            "${(targetHours > 0 ? (hours / targetHours * 100) : 0).toStringAsFixed(1)}%",
                            target.color),
                        const Divider(height: 30),
                        _buildStatRow(
                            "剩余",
                            "${(targetHours - hours).clamp(0, targetHours).toStringAsFixed(1)} 小时",
                            target.color),
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
                          leading: Icon(Icons.access_time, color: target.color),
                          title: Text(
                              "${slot.hour}:${(slot.minute10 * 10).toString().padLeft(2, '0')}"),
                          trailing: const Text("+10 分钟",
                              style: TextStyle(color: Colors.grey)),
                        );
                      }).toList(),
                      if (recordedSlots.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text("暂无记录",
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

  Widget _buildStatRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 16, color: Colors.black87)),
        Text(value,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}
