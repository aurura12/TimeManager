import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/check_in_goal.dart';
import '../services/app_log_service.dart';
import '../services/check_in_reminder_service.dart';
import '../services/check_in_sync_service.dart';
import '../utils/app_snack_bar.dart';
import 'check_in_detail_screen.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class CheckInArchiveScreen extends StatefulWidget {
  const CheckInArchiveScreen({super.key, required this.syncService});

  final CheckInSyncService syncService;

  @override
  State<CheckInArchiveScreen> createState() => _CheckInArchiveScreenState();
}

class _CheckInArchiveScreenState extends State<CheckInArchiveScreen> {
  List<CheckInGoal> get _archivedGoals =>
      widget.syncService.goalsWithRecords.where((g) => g.isArchived).toList();

  /// 恢复是纯元数据切换（归档页随时能再归档），不弹确认，点了就生效。
  Future<void> _restoreGoal(CheckInGoal goal) async {
    final updated = goal.copyWith(isArchived: false, archivedAt: null);
    final result = await widget.syncService.saveGoal(updated);
    if (!mounted) return;
    setState(() {});
    if (result.success) {
      // 归档时把提醒停掉了，恢复后要重新排上（这条路径不经过编辑页）。
      // 提醒失败不该让恢复看起来失败，单独记日志。
      try {
        await CheckInReminderService.syncGoal(updated);
      } catch (error, stackTrace) {
        AppLogService.instance.error(
          '恢复目标后重排提醒失败',
          source: 'check_in_archive',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!mounted) return;
    }
    showAppSnackBar(
      context,
      result.success
          ? (result.warning ?? '已恢复「${goal.name}」')
          : (result.error ?? '恢复失败'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('已归档的目标', style: AppText.pageTitle),
        centerTitle: true,
      ),
      body: _archivedGoals.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.archive,
                      size: 48,
                      color:
                          colorScheme.onSurfaceVariant.withValues(alpha: 0.45)),
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
      shape: RoundedRectangleBorder(borderRadius: AppRadius.controlAll),
      child: InkWell(
        borderRadius: AppRadius.controlAll,
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
                  color: AppSemanticColors.tint(
                      goal.color, AppSurfaces.of(context).page, 0.2),
                  borderRadius: AppRadius.controlAll,
                ),
                child: Icon(goal.icon,
                    color: AppSemanticColors.onTint(
                        goal.color, AppSurfaces.of(context).page,
                        alpha: 0.2),
                    size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      goal.name,
                      style: AppText.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '归档于 $archivedDate · ${goal.records.length} 次打卡',
                      style: AppText.caption.copyWith(
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
