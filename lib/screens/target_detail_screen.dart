import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/target.dart';
import 'add_target_screen.dart';
import '../widgets/target_stats_section.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class TargetDetailScreen extends StatefulWidget {
  final String targetId;

  const TargetDetailScreen({super.key, required this.targetId});

  @override
  State<TargetDetailScreen> createState() => _TargetDetailScreenState();
}

class _TargetDetailScreenState extends State<TargetDetailScreen> {
  bool _historyExpanded = false;
  bool _deletionNoticeScheduled = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<TimeProvider>(
      builder: (context, timeProvider, child) {
        final target = timeProvider.targetById(widget.targetId);
        if (target == null) {
          _scheduleDeletedTargetReturn();
          return _buildDeletedTargetScaffold();
        }

        final colorScheme = Theme.of(context).colorScheme;
        final history = timeProvider.getTargetHistory(target);

        return Scaffold(
          appBar: AppBar(
            title: Text(target.name),
            centerTitle: true,
            leading: IconButton(
              icon: const Icon(Icons.chevron_left, size: 30),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () async {
                  await Navigator.push<Target>(
                    context,
                    MaterialPageRoute(
                      builder: (context) => AddTargetScreen(target: target),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text("确认删除"),
                      content: Text('确定要删除目标"${target.name}"吗？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text("取消"),
                        ),
                        TextButton(
                          onPressed: () {
                            // 本次删除会主动关闭详情页；先标记为已处理，避免
                            // Provider 通知触发空目标重建后再次 post-frame pop，
                            // 把搜索结果页等上一层也误关闭。
                            _deletionNoticeScheduled = true;
                            timeProvider.deleteTarget(target);
                            Navigator.pop(dialogContext);
                            if (mounted && Navigator.of(context).canPop()) {
                              Navigator.pop(context);
                            }
                          },
                          style: TextButton.styleFrom(
                              foregroundColor: AppSemanticColors.readableOn(
                                  AppSemanticColors.danger,
                                  AppSurfaces.of(context).card)),
                          child: const Text("删除"),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTargetInfoCard(target, colorScheme),
                const SizedBox(height: 16),
                TargetStatsSection(
                  target: target,
                  provider: timeProvider,
                ),
                if (history.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _buildHistorySection(history, target, colorScheme),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDeletedTargetScaffold() {
    return Scaffold(
      appBar: AppBar(title: const Text('目标已删除')),
      body: const Center(
        child: Text('该目标已被删除，正在返回上一页'),
      ),
    );
  }

  void _scheduleDeletedTargetReturn() {
    if (_deletionNoticeScheduled) return;
    _deletionNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('目标已被删除')),
      );
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });
  }

  Widget _buildTargetInfoCard(Target target, ColorScheme colorScheme) {
    final surface = AppSurfaces.of(context).card;
    final iconBg = AppSemanticColors.tint(target.color, surface);
    final onIconBg = AppSemanticColors.onTint(target.color, surface);
    final previewText = _getPreviewText(target);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: AppRadius.controlAll,
              ),
              alignment: Alignment.center,
              child: Icon(
                _getTypeIcon(target.type),
                color: onIconBg,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    previewText,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: AppRadius.badgeAll,
              ),
              child: Text(
                target.period,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySection(
    Map<String, List<String>> history,
    Target target,
    ColorScheme colorScheme,
  ) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _historyExpanded = !_historyExpanded;
              });
            },
            borderRadius: const BorderRadius.vertical(top: AppRadius.rControl),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '历史记录',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '${history.length}天有记录',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _historyExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_historyExpanded) ...[
            const Divider(height: 1),
            ...history.entries.take(30).map((entry) {
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.key,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...entry.value.map((range) => Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            '$range ${target.name}',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )),
                  ],
                ),
              );
            }),
            if (history.length > 30)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    '仅显示最近30天记录',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  IconData _getTypeIcon(TargetType type) {
    switch (type) {
      case TargetType.duration:
        return Icons.timer_outlined;
      case TargetType.frequency:
        return Icons.repeat_outlined;
      case TargetType.timePoint:
        return Icons.access_time_outlined;
    }
  }

  String _getPreviewText(Target target) {
    switch (target.type) {
      case TargetType.duration:
        return '${target.compareType} ${target.durationHours}小时';
      case TargetType.frequency:
        return '${target.compareType} ${target.frequencyCount}次';
      case TargetType.timePoint:
        return '${target.targetTime}${target.compareType}${target.startTime.isNotEmpty ? "（${target.startTime}~${target.endTime}）" : ""}';
    }
  }
}
