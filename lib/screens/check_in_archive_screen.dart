import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/check_in_goal.dart';
import '../services/check_in_sync_service.dart';
import 'check_in_detail_screen.dart';

class CheckInArchiveScreen extends StatefulWidget {
  const CheckInArchiveScreen({super.key, required this.syncService});

  final CheckInSyncService syncService;

  @override
  State<CheckInArchiveScreen> createState() => _CheckInArchiveScreenState();
}

class _CheckInArchiveScreenState extends State<CheckInArchiveScreen> {
  List<CheckInGoal> get _archivedGoals =>
      widget.syncService.goalsWithRecords.where((g) => g.isArchived).toList();

  Future<void> _restoreGoal(CheckInGoal goal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复目标'),
        content: Text('确认恢复「${goal.name}」到活跃列表吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final updated = goal.copyWith(isArchived: false, archivedAt: null);
    final result = await widget.syncService.saveGoal(updated);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.success ? '已恢复「${goal.name}」' : (result.error ?? '恢复失败')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('已归档的目标', style: TextStyle(fontSize: 18)),
        centerTitle: true,
      ),
      body: _archivedGoals.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.archive,
                      size: 48,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45)),
                  const SizedBox(height: 12),
                  Text(
                    '暂无归档目标',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _archivedGoals.length,
              itemBuilder: (context, index) {
                final goal = _archivedGoals[index];
                return _buildGoalTile(goal, colorScheme);
              },
            ),
    );
  }

  Widget _buildGoalTile(CheckInGoal goal, ColorScheme colorScheme) {
    final archivedDate = goal.archivedAt != null
        ? DateFormat('yyyy年M月d日').format(goal.archivedAt!)
        : '未知';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CheckInDetailScreen(
                goal: goal,
                syncService: widget.syncService,
              ),
            ),
          );
          if (mounted) setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: goal.color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(goal.icon, color: goal.color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      goal.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '归档于 $archivedDate · ${goal.records.length} 次打卡',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.restore, size: 20),
                tooltip: '恢复',
                onPressed: () => _restoreGoal(goal),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
