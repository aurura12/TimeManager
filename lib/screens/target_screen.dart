import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import 'target_detail_screen.dart';
import 'add_target_screen.dart';

class TargetScreen extends StatelessWidget {
  const TargetScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('我的计划',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        centerTitle: true,
        backgroundColor: const Color(0xFF96B462), // 图片中的草绿色
        elevation: 0,
        // 如果是在底部导航栏的主页，通常不需要 leading 返回键，如有需要可自行开启
        actions: [
          IconButton(
            icon: const Icon(Icons.add, color: Colors.white),
            onPressed: () {
              // 点击跳转到添加目标页面
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => AddTargetScreen()),
              );
            },
          ),
        ],
      ),
      body: Consumer<TimeProvider>(
        builder: (context, timeProvider, child) {
          // --- 逻辑计算部分：保留并优化你原始代码的逻辑 ---
          final recordedSlots =
              timeProvider.slots.where((s) => s.recorded).toList();
          final totalMinutes = recordedSlots.length * 10;
          final double hours = totalMinutes / 60.0;

          // 假设目标是 6 小时 (360 分钟)
          final double percent = (totalMinutes / 360.0 * 100).clamp(0.0, 100.0);

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              // 1. 运动目标卡片 (红色)
              _buildTargetCard(
                subtitle: "每周",
                title: "运动超过6小时",
                progressText:
                    "已完成：${hours.toStringAsFixed(1)}小时(${percent.toStringAsFixed(1)}%)",
                color: const Color(0xFFF16B77),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => TargetDetailScreen()),
                  );
                },
              ),

              // 2. 睡眠目标卡片 (橙色)
              _buildTargetCard(
                title: "22:00之前睡觉",
                progressText: "坚持了：0天",
                color: const Color(0xFFF98E45),
              ),

              // 3. 冥想目标卡片 (黄色)
              _buildTargetCard(
                subtitle: "每周",
                title: "冥想超过3次",
                progressText: "已完成：0/3",
                color: const Color(0xFFD9BD2E),
              ),
            ],
          );
        },
      ),
    );
  }

  // 自定义目标卡片构建方法
  Widget _buildTargetCard({
    String? subtitle,
    required String title,
    required String progressText,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        padding: const EdgeInsets.all(20.0),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle != null)
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                progressText,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
