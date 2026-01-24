import 'dart:async';
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
        title: Text(target.name, style: const TextStyle(color: Colors.white)),
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
          // --- 1. 计算卡片显示数据 (复用 TargetScreen 逻辑) ---
          String progressText = "";
          String title = "";
          double currentValue = timeProvider.calculateTargetProgress(target);

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
            final days = timeProvider.getTargetPersistenceDays(target);
            progressText = "坚持了$days天";
            title = "${target.targetTime}${target.compareType}${target.name}";
          }

          Widget? topRightWidget;
          if (target.period.startsWith("每") &&
              target.period.endsWith("天") &&
              target.period != "每天") {
            try {
              final createTime =
                  DateTime.fromMillisecondsSinceEpoch(int.parse(target.id));
              final now = DateTime.now();
              final d1 =
                  DateTime(createTime.year, createTime.month, createTime.day);
              final d2 = DateTime(now.year, now.month, now.day);
              final days = d2.difference(d1).inDays + 1;
              topRightWidget = Text("第$days天",
                  style: const TextStyle(color: Colors.white, fontSize: 15));
            } catch (_) {}
          } else {
            DateTime? endTime;
            final nowUtc = DateTime.now().toUtc();
            final nowBeijing = nowUtc.add(const Duration(hours: 8));
            DateTime? targetBeijing;
            if (target.period == "今天") {
              targetBeijing = DateTime.utc(
                  nowBeijing.year, nowBeijing.month, nowBeijing.day + 1);
            } else if (target.period == "本周") {
              targetBeijing = DateTime.utc(nowBeijing.year, nowBeijing.month,
                  nowBeijing.day + (8 - nowBeijing.weekday));
            } else if (target.period == "本月") {
              targetBeijing =
                  DateTime.utc(nowBeijing.year, nowBeijing.month + 1, 1);
            } else if (target.period == "今年") {
              targetBeijing = DateTime.utc(nowBeijing.year + 1, 1, 1);
            }

            if (targetBeijing != null) {
              endTime = targetBeijing.subtract(const Duration(hours: 8));
              topRightWidget = _CountdownText(
                endTime: endTime,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              );
            }
          }

          // --- 2. 获取历史记录 (合并时间段) ---
          final history = timeProvider.getTargetHistory(target);

          return SingleChildScrollView(
            child: Column(
              children: [
                // 1. 目标卡片 (复用样式)
                _buildTargetCard(
                  subtitle: target.period,
                  title: title,
                  progressText: progressText,
                  topRightWidget: topRightWidget,
                  color: target.color,
                ),

                // 2. 底部记录列表 (展示具体的片段)
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("时间分布详情",
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      if (history.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text("暂无记录",
                              style: TextStyle(color: Colors.grey)),
                        )
                      else
                        ...history.entries.map((entry) {
                          return SizedBox(
                            width: double.infinity, // 【关键】确保每一组记录的容器撑满宽度
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start, // 强制左对齐
                              children: [
                                Text(entry.key,
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                ...entry.value.map((range) => Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 4.0),
                                      child: Text("$range ${target.name}",
                                          textAlign:
                                              TextAlign.left, // 【关键】强制文字对齐
                                          style: const TextStyle(
                                              fontSize: 15,
                                              color: Colors.black87)),
                                    )),
                                const SizedBox(height: 16),
                              ],
                            ),
                          );
                        }),
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

  Widget _buildTargetCard({
    String? subtitle,
    required String title,
    required String progressText,
    Widget? topRightWidget,
    required Color color,
  }) {
    return Container(
      margin: const EdgeInsets.all(16.0),
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

    return Text("剩余 $text", style: widget.style);
  }
}
