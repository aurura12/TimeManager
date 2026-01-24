import 'dart:async';
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

              // 使用 Provider 计算当前周期的进度
              double currentValue =
                  timeProvider.calculateTargetProgress(target);

              if (target.type == TargetType.duration) {
                final double hours = currentValue;
                final double percent = target.durationHours > 0
                    ? (hours / target.durationHours * 100).clamp(0.0, 100.0)
                    : 0.0;
                progressText =
                    "已完成：${hours.toStringAsFixed(1)}小时(${percent.toStringAsFixed(1)}%)";
                title =
                    "${target.name}${target.compareType}${target.durationHours}小时";
              } else if (target.type == TargetType.frequency) {
                final int count = currentValue.toInt();
                progressText = "已完成 $count/${target.frequencyCount}";
                title =
                    "${target.name}${target.compareType}${target.frequencyCount}次";
              } else {
                final days = timeProvider.getTargetPersistenceDays(target.name);
                progressText = "坚持了$days天";
                title =
                    "${target.targetTime}${target.compareType}${target.name}";
              }

              Widget? topRightWidget;
              if (target.period.startsWith("每") &&
                  target.period.endsWith("天") &&
                  target.period != "每天") {
                try {
                  final createTime =
                      DateTime.fromMillisecondsSinceEpoch(int.parse(target.id));
                  final now = DateTime.now();
                  final d1 = DateTime(
                      createTime.year, createTime.month, createTime.day);
                  final d2 = DateTime(now.year, now.month, now.day);
                  final days = d2.difference(d1).inDays + 1;
                  topRightWidget = Text("第$days天",
                      style:
                          const TextStyle(color: Colors.white, fontSize: 15));
                } catch (_) {}
              } else {
                DateTime? endTime;
                // 获取当前 UTC 时间并转换为北京时间（UTC+8）的日期组件
                final nowUtc = DateTime.now().toUtc();
                final nowBeijing = nowUtc.add(const Duration(hours: 8));

                // 计算北京时间下的截止时间（此时得到的 targetBeijing 是以 UTC 容器存储的北京时间墙钟）
                DateTime? targetBeijing;
                if (target.period == "今天") {
                  targetBeijing = DateTime.utc(
                      nowBeijing.year, nowBeijing.month, nowBeijing.day + 1);
                } else if (target.period == "本周") {
                  targetBeijing = DateTime.utc(
                      nowBeijing.year,
                      nowBeijing.month,
                      nowBeijing.day + (8 - nowBeijing.weekday));
                } else if (target.period == "本月") {
                  targetBeijing =
                      DateTime.utc(nowBeijing.year, nowBeijing.month + 1, 1);
                } else if (target.period == "今年") {
                  targetBeijing = DateTime.utc(nowBeijing.year + 1, 1, 1);
                }

                if (targetBeijing != null) {
                  // 将北京时间的截止时间还原为真实的 UTC 时间戳
                  // 因为 targetBeijing 是北京时间（比 UTC 快 8 小时），所以要减去 8 小时才是真实的 UTC 截止时间
                  endTime = targetBeijing.subtract(const Duration(hours: 8));

                  topRightWidget = _CountdownText(
                    endTime: endTime,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  );
                }
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
                  topRightWidget: topRightWidget,
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
    Widget? topRightWidget,
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                if (topRightWidget != null) topRightWidget,
              ],
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

class _CountdownText extends StatefulWidget {
  final DateTime endTime;
  final TextStyle style;

  const _CountdownText({required this.endTime, required this.style});

  @override
  State<_CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<_CountdownText> {
  late Timer _timer;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _updateTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());
  }

  void _updateTime() {
    final now = DateTime.now().toUtc();
    final diff = widget.endTime.difference(now);
    if (mounted) {
      setState(() {
        _remaining = diff.isNegative ? Duration.zero : diff;
      });
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = _remaining.inDays;
    final hours = _remaining.inHours % 24;
    final minutes = _remaining.inMinutes % 60;
    final seconds = _remaining.inSeconds % 60;

    String text;
    if (days > 0) {
      text =
          "$days天 ${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
    } else {
      text =
          "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
    }

    return Text(" $text", style: widget.style);
  }
}
