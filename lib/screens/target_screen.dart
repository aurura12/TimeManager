import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import 'target_detail_screen.dart';
import 'add_target_screen.dart';
import '../models/target.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

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
          if (timeProvider.targets.isEmpty) {
            return const Center(
              child: Text("暂无计划，点击右上角添加", style: TextStyle(color: Colors.grey)),
            );
          }

          return ReorderableListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            onReorder: (oldIndex, newIndex) {
              timeProvider.reorderTargets(oldIndex, newIndex);
            },
            children: timeProvider.targets.map((target) {
              // 动态计算进度 (目前主要实现时长类型的计算)
              String progressText = "";
              String title = "";

              if (target.type == TargetType.duration) {
                final recordedSlots = timeProvider.slots
                    .where((s) => s.recorded && s.label == target.name)
                    .toList();
                final totalMinutes = recordedSlots.length * 10;
                final double hours = totalMinutes / 60.0;
                final double percent = target.durationHours > 0
                    ? (hours / target.durationHours * 100).clamp(0.0, 100.0)
                    : 0.0;
                progressText =
                    "已完成：${hours.toStringAsFixed(1)}小时(${percent.toStringAsFixed(1)}%)";
                title =
                    "${target.name}${target.compareType}${target.durationHours}小时";
              } else if (target.type == TargetType.frequency) {
                final currentCount = timeProvider.slots
                    .where((s) => s.recorded && s.label == target.name)
                    .length;
                progressText = "已完成 $currentCount/${target.frequencyCount}";
                title =
                    "${target.name}${target.compareType}${target.frequencyCount}次";
              } else {
                final days = timeProvider.getTargetPersistenceDays(target.name);
                progressText = "坚持了$days天";
                title =
                    "${target.targetTime}${target.compareType}${target.name}";
              }

              return Slidable(
                key: ValueKey(target), // 必须有 Key
                endActionPane: ActionPane(
                  motion: const ScrollMotion(),
                  extentRatio: 0.2, // 侧滑按钮占据的宽度比例
                  children: [
                    // 编辑和删除按钮上下排列
                    Expanded(
                      child: Column(
                        children: [
                          // 编辑按钮
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                // 处理编辑逻辑
                                print("编辑 ${target.name}");
                              },
                              child: const Center(
                                child:
                                    Icon(Icons.edit, color: Color(0xFF96B462)),
                              ),
                            ),
                          ),
                          // 删除按钮
                          Expanded(
                            child: InkWell(
                              onTap: () =>
                                  _confirmDelete(context, timeProvider, target),
                              child: const Center(
                                child: Icon(Icons.delete_forever,
                                    color: Colors.redAccent),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                child: _buildTargetCard(
                  key: ValueKey("card_${target.name}"), // 这里用不同的 key 区分
                  subtitle: target.period,
                  title: title,
                  progressText: progressText,
                  color: target.color,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            TargetDetailScreen(target: target),
                      ),
                    );
                  },
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  // 自定义目标卡片构建方法
  Widget _buildTargetCard({
    required Key key,
    String? subtitle,
    required String title,
    required String progressText,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        padding: const EdgeInsets.all(20.0),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
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

  Future<void> _confirmDelete(
      BuildContext context, TimeProvider provider, Target target) async {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除目标“${target.name}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              provider.deleteTarget(target); // 请确保你的 TimeProvider 中有这个方法
              Navigator.pop(context);
            },
            child: const Text('确认', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
