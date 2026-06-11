import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/target.dart';
import 'add_target_screen.dart';
import '../widgets/target_stats_section.dart';

class TargetDetailScreen extends StatelessWidget {
  final Target target;

  const TargetDetailScreen({super.key, required this.target});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : Colors.white,
      appBar: AppBar(
        title: Text(target.name, style: TextStyle(color: Colors.white)),
        centerTitle: true,
        backgroundColor: target.color,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit, color: Colors.white),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AddTargetScreen(target: target),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text("确认删除"),
                  content: Text('确定要删除目标"${target.name}"吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("取消"),
                    ),
                    TextButton(
                      onPressed: () {
                        Provider.of<TimeProvider>(context, listen: false)
                            .deleteTarget(target);
                        Navigator.pop(context);
                        Navigator.pop(context);
                      },
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text("删除"),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<TimeProvider>(
        builder: (context, timeProvider, child) {
          final isCompleted = timeProvider.isTargetCompleted(target, DateTime.now());
          final todayCount = timeProvider.getTargetTodayCount(target);

          return Column(
            children: [
              // 顶部完成状态卡片
              _buildCompletionCard(
                context: context,
                target: target,
                isCompleted: isCompleted,
                todayCount: todayCount,
                provider: timeProvider,
                colorScheme: colorScheme,
              ),

              // 统计内容
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: TargetStatsSection(
                    target: target,
                    provider: timeProvider,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCompletionCard({
    required BuildContext context,
    required Target target,
    required bool isCompleted,
    required int todayCount,
    required TimeProvider provider,
    required ColorScheme colorScheme,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: target.color,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            '今天${target.name.substring(0, target.name.length.clamp(0, 2))}了吗',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildStatChip(
                icon: Icons.check_circle_outline,
                label: '$todayCount 次',
                color: Colors.white,
              ),
              const SizedBox(width: 16),
              _buildStatChip(
                icon: Icons.calendar_today,
                label: target.period,
                color: Colors.white,
              ),
              const SizedBox(width: 16),
              _buildStatChip(
                icon: isCompleted ? Icons.notifications_active : Icons.notifications_off,
                label: isCompleted ? '已完成' : '未完成',
                color: Colors.white,
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                provider.toggleTargetCompletion(target, DateTime.now());
              },
              icon: Icon(
                isCompleted ? Icons.check : Icons.add,
                color: target.color,
              ),
              label: Text(
                isCompleted ? '取消完成' : '标记完成',
                style: TextStyle(color: target.color, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color.withValues(alpha: 0.9), size: 18),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(color: color.withValues(alpha: 0.9), fontSize: 14),
        ),
      ],
    );
  }
}
