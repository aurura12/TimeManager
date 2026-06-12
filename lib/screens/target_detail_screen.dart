import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/target.dart';
import 'add_target_screen.dart';
import '../widgets/target_stats_section.dart';

class TargetDetailScreen extends StatefulWidget {
  final Target target;

  const TargetDetailScreen({super.key, required this.target});

  @override
  State<TargetDetailScreen> createState() => _TargetDetailScreenState();
}

class _TargetDetailScreenState extends State<TargetDetailScreen> {
  bool _historyExpanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final target = widget.target;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : Colors.white,
      appBar: AppBar(
        title: Text(target.name, style: TextStyle(color: isDark ? colorScheme.onSurface : Colors.white)),
        centerTitle: true,
        backgroundColor: isDark ? colorScheme.surface : const Color(0xFF96B462),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
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
          final history = timeProvider.getTargetHistory(target);

          return SingleChildScrollView(
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
                  _buildHistorySection(history, colorScheme),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTargetInfoCard(Target target, ColorScheme colorScheme) {
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
                color: target.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(
                _getTypeIcon(target.type),
                color: target.color,
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
                borderRadius: BorderRadius.circular(8),
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

  Widget _buildHistorySection(Map<String, List<String>> history, ColorScheme colorScheme) {
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
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
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
                        _historyExpanded ? Icons.expand_less : Icons.expand_more,
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                        '$range ${widget.target.name}',
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
