import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/sync_center_state.dart';
import '../services/sync_center_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'app_log_screen.dart';

class SyncCenterScreen extends StatefulWidget {
  const SyncCenterScreen({
    super.key,
    this.controller,
  });

  /// 仅供测试注入；生产环境从当前 [TimeProvider] 创建控制器。
  final SyncCenterController? controller;

  @override
  State<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends State<SyncCenterScreen> {
  late final SyncCenterController _controller;

  @override
  void initState() {
    super.initState();
    // 生产环境使用全局控制器：日程页/出行页/后台同步上报的状态与这里
    // 共享同一份数据，因此重新打开页面不会退回“尚未检查”。
    _controller = widget.controller ?? context.read<SyncCenterController>();
    unawaited(_controller.initialize());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final colorScheme = Theme.of(context).colorScheme;
        return Scaffold(
          backgroundColor: colorScheme.surface,
          appBar: AppBar(
            title: const Text('同步中心'),
            actions: [
              IconButton(
                tooltip: '刷新状态',
                onPressed: _controller.isRetrying ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
              TextButton(
                onPressed: _controller.isRetrying ? null : _retryAll,
                child: const Text('全部重试'),
              ),
            ],
          ),
          body: _controller.isInitialized
              ? _buildContent(context)
              : const Center(child: CircularProgressIndicator()),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final issueMessage = _controller.hasIssue
        ? '同步状态会保留在本地；离线或失败项恢复网络后可单独重试。'
        : '同步中心会按模块显示待上传、待下载和最近一次成功同步时间。';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageHorizontal,
        AppSpacing.md,
        AppSpacing.pageHorizontal,
        AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: surfaces.card,
            child: Padding(
              padding: AppSpacing.cardComfortable,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.sync_rounded, color: colorScheme.primary),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text('同步概览', style: AppText.sectionTitle),
                      ),
                      Text(
                        _controller.isRetrying
                            ? '处理中'
                            : '共 ${_controller.pendingCount} 项待处理',
                        style: AppText.caption.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    issueMessage,
                    style: AppText.body.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  OutlinedButton.icon(
                    onPressed: () => _openLogs(context),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('查看同步日志'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          for (final state in _controller.states) ...[
            _buildModuleCard(context, state),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _buildModuleCard(BuildContext context, SyncModuleState state) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final color = _statusColor(state.status, colorScheme);
    final onTint = AppSemanticColors.onTint(color, surfaces.card, alpha: 0.12);
    final issue = <String>[
      if (state.failureCount > 0) '失败 ${state.failureCount}',
      if (state.conflictCount > 0) '冲突 ${state.conflictCount}',
    ];

    return Card(
      color: surfaces.card,
      child: Padding(
        padding: AppSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_moduleIcon(state.module), color: color),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(state.module.label, style: AppText.sectionTitle),
                ),
                Container(
                  padding: AppSpacing.chip,
                  decoration: BoxDecoration(
                    color: AppSemanticColors.tint(color, surfaces.card, 0.12),
                    borderRadius: AppRadius.badgeAll,
                  ),
                  child: Text(
                    state.status.label,
                    style: AppText.badge.copyWith(color: onTint),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '最后成功：${_formatLastSuccess(state.lastSuccessAt)}',
              style: AppText.caption.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '待同步：上传 ${state.pendingUploadCount} · 下载 ${state.pendingDownloadCount}',
              style: AppText.caption.copyWith(
                color: state.hasPending ? color : colorScheme.onSurfaceVariant,
              ),
            ),
            if (state.lastAttemptAt != null &&
                state.status != SyncModuleStatus.success) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                '最近尝试：${_formatLastSuccess(state.lastAttemptAt)}',
                style: AppText.caption.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (issue.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                issue.join(' · '),
                style: AppText.caption.copyWith(color: color),
              ),
            ],
            if (state.message != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                state.message!,
                style: AppText.body.copyWith(
                  color: state.hasIssue ? color : colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (state.details.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              for (final detail in state.details)
                Text(
                  '• $detail',
                  style: AppText.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                key: ValueKey('sync-center-retry-${state.module.name}'),
                onPressed:
                    !state.enabled || _controller.isRetryingModule(state.module)
                        ? null
                        : () => _retry(state.module),
                icon: const Icon(Icons.refresh),
                label: const Text('重试此模块'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    await _controller.refresh();
  }

  Future<void> _retry(SyncModule module) async {
    await _controller.retry(module);
    if (!mounted) return;
    final state = _controller.stateFor(module);
    if (state.hasIssue) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.message ?? '${module.label}同步未完成')),
      );
    }
  }

  Future<void> _retryAll() async {
    await _controller.retryAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _controller.hasIssue ? '部分模块仍需处理' : '全部同步任务已完成',
        ),
      ),
    );
  }

  Future<void> _openLogs(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const AppLogScreen()),
    );
  }

  String _formatLastSuccess(DateTime? value) {
    if (value == null) return '暂无记录';
    return DateFormat('yyyy-MM-dd HH:mm').format(value);
  }

  Color _statusColor(SyncModuleStatus status, ColorScheme colorScheme) {
    return switch (status) {
      SyncModuleStatus.success => AppSemanticColors.success,
      SyncModuleStatus.pending => AppSemanticColors.warning,
      SyncModuleStatus.syncing => AppSemanticColors.info,
      SyncModuleStatus.offline => AppSemanticColors.warning,
      SyncModuleStatus.failed || SyncModuleStatus.conflict => colorScheme.error,
      SyncModuleStatus.disabled ||
      SyncModuleStatus.idle ||
      SyncModuleStatus.busy =>
        colorScheme.onSurfaceVariant,
    };
  }

  IconData _moduleIcon(SyncModule module) {
    return switch (module) {
      SyncModule.schedule => Icons.event_note_outlined,
      SyncModule.categories => Icons.category_outlined,
      SyncModule.targets => Icons.flag_outlined,
      SyncModule.diary => Icons.menu_book_outlined,
      SyncModule.travel => Icons.card_travel_outlined,
      SyncModule.checkIn => Icons.check_circle_outline,
      SyncModule.googleCalendar => Icons.calendar_month_outlined,
    };
  }
}
