import 'package:flutter/material.dart';

import '../models/schedule_sync_progress.dart';

import '../theme/app_semantic_colors.dart';
class ScheduleSyncProgressBanner extends StatelessWidget {
  const ScheduleSyncProgressBanner({
    super.key,
    required this.progress,
  });

  final ScheduleSyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = progress.isError
        ? colorScheme.error
        : progress.isFinished
            ? AppSemanticColors.brand
            : colorScheme.primary;
    // brand 绿在白底只有 2.2:1，当文字/图标用要先压到可读
    final textColor = AppSemanticColors.readableOn(color, colorScheme.surface);
    final progressText =
        progress.total > 0 ? '${progress.completed}/${progress.total}' : null;

    return Material(
      color: colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    progress.isError
                        ? Icons.error_outline
                        : progress.isFinished
                            ? Icons.check_circle_outline
                            : Icons.sync,
                    size: 18,
                    color: textColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      progress.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (progressText != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      progressText,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
              if (!progress.isFinished && !progress.isError) ...[
                const SizedBox(height: 7),
                LinearProgressIndicator(
                  value: progress.value,
                  color: color,
                  backgroundColor:
                      AppSemanticColors.tint(color, colorScheme.surface, 0.14),
                  minHeight: 3,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
