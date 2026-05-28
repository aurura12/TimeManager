import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/time_provider.dart';
import '../services/google_calendar_service.dart';

class CalendarSyncStatusBadge extends StatelessWidget {
  final VoidCallback? onNotLoggedIn;

  const CalendarSyncStatusBadge({super.key, this.onNotLoggedIn});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimeProvider>();
    final loggedIn = GoogleCalendarService.isSignedIn;

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

        if (!loggedIn) {
          label = '未连接';
          color = Colors.grey;
          icon = Icons.cloud_off_outlined;
          tooltip = '未连接 Google 日历，点击前往账户设置';
        } else if (syncing) {
          label = '同步中';
          color = const Color(0xFF9CB86A);
          icon = Icons.sync;
          tooltip = '正在同步 Google 日历…';
        } else if (pendingCount > 0) {
          label = pendingCount > 1 ? '待同步 $pendingCount' : '待同步';
          color = Colors.orange;
          icon = Icons.cloud_upload_outlined;
          tooltip = '有 $pendingCount 天本地记录尚未同步，点击立即同步';
        } else {
          label = '已连接';
          color = const Color(0xFF9CB86A);
          icon = Icons.cloud_done_outlined;
          tooltip = 'Google 日历已连接，点击手动同步';
        }

        return Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              onTap: () {
                if (!loggedIn) {
                  onNotLoggedIn?.call();
                } else if (hasPending) {
                  provider.synchronizeAllPendingCalendars();
                } else {
                  provider.synchronizeCalendar();
                }
              },
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withValues(alpha: 0.35)),
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
                          color: color,
                        ),
                      )
                    else
                      Icon(icon, size: 14, color: color),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: color.withValues(alpha: 0.95),
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
}
