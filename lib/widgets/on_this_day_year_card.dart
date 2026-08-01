import 'package:flutter/material.dart';

import '../models/on_this_day_entry.dart';

/// 统一的时长格式化（中文，如 "1小时30分钟" / "45分钟"）
String formatOnThisDayDuration(int minutes) {
  if (minutes >= 60) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m > 0 ? '$h小时$m分钟' : '$h小时';
  }
  return '$minutes分钟';
}

/// 紧凑时长格式化（chips 用，如 "1h30m" / "45m"）
String formatOnThisDayDurationCompact(int minutes) {
  if (minutes >= 60) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m > 0 ? '${h}h${m}m' : '${h}h';
  }
  return '${minutes}m';
}

/// "那年今日"某个年份的卡片：展示时间记录 / 出行 / 日记摘要。
/// 弹窗和独立页面共用。
class OnThisDayYearCard extends StatelessWidget {
  final OnThisDayEntry entry;

  const OnThisDayYearCard({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${entry.year}年 · ${entry.yearsAgoLabel}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const Spacer(),
                if (entry.totalMinutes > 0)
                  Text(
                    '共 ${formatOnThisDayDuration(entry.totalMinutes)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // 时间记录（活动时长）
            if (entry.activities.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final a in entry.activities.take(5))
                    _ActivityChip(label: a.label, minutes: a.minutes),
                ],
              ),
              const SizedBox(height: 10),
            ],

            // 出行记录
            if (entry.hasTravel) ...[
              _InfoRow(
                icon: '✈️',
                text: '去了「${entry.travelLocation}」'
                    '${entry.travelEvent != null && entry.travelEvent!.isNotEmpty ? ' · ${entry.travelEvent}' : ''}',
              ),
              const SizedBox(height: 8),
            ],

            // 日记摘要
            if (entry.diaryGuaiGuai != null)
              _DiaryRow(nickname: '乖乖', content: entry.diaryGuaiGuai!),
            if (entry.diaryJingJing != null)
              _DiaryRow(nickname: '晶晶', content: entry.diaryJingJing!),
          ],
        ),
      ),
    );
  }
}

class _ActivityChip extends StatelessWidget {
  final String label;
  final int minutes;

  const _ActivityChip({required this.label, required this.minutes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label ${formatOnThisDayDurationCompact(minutes)}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String icon;
  final String text;

  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(icon, style: theme.textTheme.bodyMedium),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _DiaryRow extends StatelessWidget {
  final String nickname;
  final String content;

  const _DiaryRow({required this.nickname, required this.content});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              nickname,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '"$content"',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
