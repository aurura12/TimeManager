import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/sync_center_state.dart';
import '../screens/sync_center_screen.dart';
import '../services/sync_center_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 页面顶栏的「同步状态灯」。
///
/// 页面本身不再提供同步动作：一切正常时不占位，同步中显示转圈，
/// 待同步 / 离线显示黄点，失败 / 冲突显示红点；点击进入同步中心处理。
class SyncStatusButton extends StatelessWidget {
  const SyncStatusButton({
    super.key,
    required this.modules,
    this.controller,
    this.onPressed,
  });

  /// 本页关注的同步模块，取其中最严重的状态展示。
  final List<SyncModule> modules;

  /// 仅供测试注入；生产环境从 Provider 读取全局控制器。
  final SyncCenterController? controller;

  /// 默认打开同步中心；需要定位到具体模块时由页面传入。
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final center = controller ?? context.watch<SyncCenterController?>();
    if (center == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: center,
      builder: (context, _) {
        final state = _worstState(center);
        if (state == null) return const SizedBox.shrink();
        if (_isRunning(state.status)) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final surfaces = AppSurfaces.of(context);
        final color = AppSemanticColors.readableOn(
          _statusColor(state.status, Theme.of(context).colorScheme),
          surfaces.panel,
          minRatio: 3.0,
        );
        return IconButton(
          tooltip: _tooltip(state),
          onPressed: onPressed ??
              () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const SyncCenterScreen(),
                    ),
                  ),
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(_statusIcon(state.status), size: AppSizes.appBarActionIcon),
              Positioned(
                right: -1,
                top: -1,
                child: Container(
                  width: AppSizes.statusDot,
                  height: AppSizes.statusDot,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 只在本页模块里挑一个「需要用户知道」的状态；全部正常时返回 null。
  SyncModuleState? _worstState(SyncCenterController center) {
    SyncModuleState? worst;
    for (final module in modules) {
      final state = center.stateFor(module);
      if (_severity(state.status) <= 0) continue;
      if (worst == null || _severity(state.status) > _severity(worst.status)) {
        worst = state;
      }
    }
    return worst;
  }

  /// 数值越大越需要提示；<= 0 表示正常、不占位。
  int _severity(SyncModuleStatus status) {
    return switch (status) {
      SyncModuleStatus.failed || SyncModuleStatus.conflict => 4,
      SyncModuleStatus.offline => 3,
      SyncModuleStatus.pending => 2,
      SyncModuleStatus.syncing || SyncModuleStatus.busy => 1,
      SyncModuleStatus.idle ||
      SyncModuleStatus.success ||
      SyncModuleStatus.skipped ||
      SyncModuleStatus.disabled =>
        0,
    };
  }

  bool _isRunning(SyncModuleStatus status) =>
      status == SyncModuleStatus.syncing || status == SyncModuleStatus.busy;

  Color _statusColor(SyncModuleStatus status, ColorScheme colorScheme) {
    return switch (status) {
      SyncModuleStatus.failed || SyncModuleStatus.conflict => colorScheme.error,
      SyncModuleStatus.offline || SyncModuleStatus.pending =>
        AppSemanticColors.warning,
      _ => colorScheme.onSurfaceVariant,
    };
  }

  IconData _statusIcon(SyncModuleStatus status) {
    return switch (status) {
      SyncModuleStatus.pending => Icons.cloud_upload_outlined,
      SyncModuleStatus.offline => Icons.cloud_off_outlined,
      SyncModuleStatus.failed || SyncModuleStatus.conflict => Icons.sync_problem,
      _ => Icons.cloud_sync_outlined,
    };
  }

  String _tooltip(SyncModuleState state) {
    final headline = '${state.module.label}：${state.status.label}';
    final message = state.message;
    if (message == null || message.trim().isEmpty) return '$headline，点击查看同步中心';
    return '$headline\n$message\n点击查看同步中心';
  }
}
