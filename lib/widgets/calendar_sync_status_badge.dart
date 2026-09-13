import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/time_provider.dart';
import '../services/google_calendar_service.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
class CalendarSyncStatusBadge extends StatelessWidget {
  final VoidCallback? onNotLoggedIn;

  const CalendarSyncStatusBadge({super.key, this.onNotLoggedIn});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimeProvider>();
    final enabled = provider.googleCalendarSyncEnabled;
    final loggedIn = GoogleCalendarService.isSignedIn;
    final needsReconnect = GoogleCalendarService.needsCalendarReconnect;

    return StreamBuilder<String>(
      stream: provider.syncStatusStream,
      initialData: 'IDLE',
      builder: (context, snapshot) {
        final syncing = snapshot.data == 'SYNCING';
        final pendingCount = provider.pendingSyncDates.length;
        final hasPending = pendingCount > 0;

        late final String label;
        late final Color color;
        late final IconData icon;
        late final String tooltip;

        if (!enabled) {
          label = '已关闭';
          color = AppSemanticColors.neutral;
          icon = Icons.sync_disabled_outlined;
          tooltip = 'Google 日历同步已关闭，前往设置可重新开启';
        } else if (!loggedIn) {
          if (needsReconnect) {
            label = '需重连';
            color = AppSemanticColors.warning;
            icon = Icons.link_off;
            tooltip = '身份已识别，但日历连接失效，点击重新连接 Google 日历';
          } else {
            label = '未连接';
            color = AppSemanticColors.neutral;
            icon = Icons.cloud_off_outlined;
            tooltip = '未连接 Google 日历，点击前往账户设置';
          }
        } else if (syncing) {
          label = '同步中';
          color = AppSemanticColors.brand;
          icon = Icons.sync;
          tooltip = '正在同步 Google 日历';
        } else if (pendingCount > 0) {
          label = pendingCount > 1 ? '待同步 $pendingCount' : '待同步';
          color = AppSemanticColors.warning;
          icon = Icons.cloud_upload_outlined;
          tooltip = '有 $pendingCount 天本地记录尚未同步，点击立即同步';
        } else {
          label = '已连接';
          color = AppSemanticColors.brand;
          icon = Icons.cloud_done_outlined;
          tooltip = 'Google 日历已连接，点击手动同步';
        }

        final surface = AppSurfaces.of(context).card;
        final badgeBg = AppSemanticColors.tint(color, surface, 0.12);
        final onBadge = AppSemanticColors.onTint(color, surface, alpha: 0.12);
        return Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              onTap: () => _onTap(
                context,
                provider,
                enabled,
                loggedIn,
                needsReconnect,
                hasPending,
              ),
              borderRadius: AppRadius.cardAll,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: AppRadius.cardAll,
                  border: Border.all(
                      color: AppSemanticColors.tint(color, surface, 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (syncing)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: onBadge,
                        ),
                      )
                    else
                      Icon(icon, size: 14, color: onBadge),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: onBadge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _onTap(
    BuildContext context,
    TimeProvider provider,
    bool enabled,
    bool loggedIn,
    bool needsReconnect,
    bool hasPending,
  ) async {
    if (!enabled) {
      onNotLoggedIn?.call();
      return;
    }

    if (!loggedIn) {
      if (needsReconnect) {
        await _reconnect(context, provider);
      } else {
        onNotLoggedIn?.call();
      }
    } else if (hasPending) {
      provider.syncAll();
    } else {
      provider.synchronizeCalendar();
    }
  }

  Future<void> _reconnect(BuildContext context, TimeProvider provider) async {
    if (!GoogleCalendarService.isConfigured) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先在 google_sign_in_config.dart 配置 OAuth 客户端 ID'),
        ),
      );
      return;
    }

    final ok = await provider.setGoogleCalendarSyncEnabled(true);
    if (!context.mounted) return;
    if (ok) {
      provider.synchronizeCalendar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google 日历已重新连接')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            GoogleCalendarService.lastLoginError ?? '重新连接失败',
          ),
        ),
      );
    }
  }
}
