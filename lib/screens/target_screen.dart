import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import 'target_detail_screen.dart';
import 'add_target_screen.dart';
import '../models/target.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/platform_features.dart';
import '../widgets/desktop_target_card.dart';
import '../widgets/main_tab_activity.dart';

class TargetScreen extends StatelessWidget {
  const TargetScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(isDesktopPlatform ? '目标' : '我的计划'),
        centerTitle: !isDesktopPlatform,
        // 如果是在底部导航栏的主页，通常不需要 leading 返回键，如有需要可自行开启
        actions: [
          if (isDesktopPlatform)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.lg),
              child: FilledButton.icon(
                onPressed: () => showTargetEditor(context),
                icon: const Icon(Icons.add),
                label: const Text('新建目标'),
              ),
            )
          else
            IconButton(
              tooltip: '新建目标',
              icon: const Icon(Icons.add),
              onPressed: () => showTargetEditor(context),
            ),
        ],
      ),
      body: Consumer<TimeProvider>(
        builder: (context, timeProvider, child) {
          if (isDesktopPlatform) {
            return _buildDesktopList(context, timeProvider);
          }
          if (timeProvider.targets.isEmpty) {
            return Center(
              child: Text(
                "暂无计划，点击右上角添加",
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            );
          }

          return ReorderableListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            onReorderItem: (oldIndex, newIndex) {
              timeProvider.reorderTargets(oldIndex, newIndex);
            },
            children: timeProvider.targets.map((target) {
              // 动态计算进度 (目前主要实现时长类型的计算)
              String progressText = "";
              String title = "";
              final cardColor = context.adaptSemanticColor(target.color);
              final onCardColor = AppSemanticColors.onColor(cardColor);

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
                final days = timeProvider.getTargetPersistenceDays(target);
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
                      style: TextStyle(color: onCardColor, fontSize: 15));
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
                    style: TextStyle(color: onCardColor, fontSize: 15),
                  );
                }
              }

              return Slidable(
                key: ValueKey(target.id), // 必须有 Key
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
                                showTargetEditor(context, target: target);
                              },
                              child: Center(
                                child: Icon(
                                  Icons.edit,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                          // 删除按钮
                          Expanded(
                            child: InkWell(
                              onTap: () =>
                                  _confirmDelete(context, timeProvider, target),
                              child: Center(
                                child: Icon(Icons.delete_forever,
                                    color: AppSemanticColors.readableOn(
                                        AppSemanticColors.danger,
                                        AppSurfaces.of(context).page)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                child: _buildTargetCard(
                  context: context,
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
                            TargetDetailScreen(targetId: target.id),
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

  Widget _buildDesktopList(BuildContext context, TimeProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    if (provider.targets.isEmpty) {
      return Center(
        child: Padding(
          padding: AppSpacing.cardComfortable,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flag_outlined,
                  size: AppSizes.minTapTarget, color: scheme.onSurfaceVariant),
              const SizedBox(height: AppSpacing.lg),
              const Text('暂无目标', style: AppText.sectionTitle),
              const SizedBox(height: AppSpacing.sm),
              Text('为已有事件设置时长、次数或时间点目标',
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: () => showTargetEditor(context),
                icon: const Icon(Icons.add),
                label: const Text('新建目标'),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: AppSizes.desktopContentMaxWidth),
        child: Column(
          children: [
            Padding(
              padding: AppSpacing.cardComfortable,
              child: Row(
                children: [
                  Expanded(
                    child: Text('共 ${provider.targets.length} 个目标',
                        style: AppText.caption
                            .copyWith(color: scheme.onSurfaceVariant)),
                  ),
                  Text('拖动把手排序 · 右键打开菜单',
                      style: AppText.caption
                          .copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                padding: AppSpacing.page,
                buildDefaultDragHandles: false,
                itemCount: provider.targets.length,
                onReorderItem: provider.reorderTargets,
                itemBuilder: (context, index) {
                  final target = provider.targets[index];
                  return DesktopTargetCard(
                    key: ValueKey(target.id),
                    target: target,
                    provider: provider,
                    index: index,
                    onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TargetDetailScreen(targetId: target.id),
                      ),
                    ),
                    onEdit: () => showTargetEditor(context, target: target),
                    onDelete: () => _confirmDelete(context, provider, target),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 自定义目标卡片构建方法
  Widget _buildTargetCard({
    required BuildContext context,
    required Key key,
    String? subtitle,
    required String title,
    required String progressText,
    Widget? topRightWidget,
    required Color color,
    VoidCallback? onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final cardColor = context.adaptSemanticColor(color);
    // 背景启用时卡片填充变半透明；文字色仍按不透明的 cardColor 算
    final cardFill = context.adaptSemanticFill(color);
    final onCardColor = AppSemanticColors.onColor(cardColor);

    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        padding: const EdgeInsets.all(20.0),
        decoration: BoxDecoration(
          color: cardFill,
          borderRadius: AppRadius.cardAll,
          // 卡片：弱边框、少阴影
          border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
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
                    style: TextStyle(
                      color: onCardColor.withValues(alpha: 0.75),
                      fontSize: 13,
                    ),
                  ),
                if (topRightWidget != null) topRightWidget,
              ],
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                color: onCardColor,
                fontSize: 19,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                progressText,
                style: TextStyle(
                  color: onCardColor.withValues(alpha: 0.92),
                  fontSize: 15,
                ),
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
            child: Text('确认',
                style: TextStyle(
                    color: AppSemanticColors.readableOn(
                        AppSemanticColors.danger,
                        AppSurfaces.of(context).card))),
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
  Timer? _timer;
  Duration _remaining = Duration.zero;
  bool _isActive = false;

  @override
  void initState() {
    super.initState();
    _updateTime();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isActive = MainTabActivity.isActiveOf(context);
    _refreshTimer();
  }

  void _refreshTimer() {
    _timer?.cancel();
    if (_isActive) {
      _updateTime();
      if (_remaining > Duration.zero) {
        _timer =
            Timer.periodic(const Duration(minutes: 1), (_) => _updateTime());
      }
    }
  }

  @override
  void didUpdateWidget(covariant _CountdownText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.endTime != oldWidget.endTime) {
      _refreshTimer();
    }
  }

  void _updateTime() {
    final now = DateTime.now().toUtc();
    final diff = widget.endTime.difference(now);
    if (mounted) {
      setState(() {
        _remaining = diff.isNegative ? Duration.zero : diff;
      });
    }
    if (diff <= Duration.zero) _timer?.cancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = _remaining.inDays;
    final hours = _remaining.inHours % 24;
    final minutes = _remaining.inMinutes % 60;

    String text;
    if (days > 0) {
      text =
          "$days天 ${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
    } else {
      text =
          "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
    }

    return Text(" $text", style: widget.style);
  }
}
