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

/// "那年今日"某个年份的卡片：展示时间记录 / 出行 / 日记（默认摘要，点击展开全文）。
/// 弹窗和独立页面共用。
///
/// [compact]：弹窗用简略模式——活动最多 3 个、日记只显示摘要不可展开。
class OnThisDayYearCard extends StatelessWidget {
  final OnThisDayEntry entry;
  final bool compact;

  const OnThisDayYearCard({super.key, required this.entry, this.compact = false});

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
                  for (final a in entry.activities.take(compact ? 3 : 5))
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
              _DiaryRow(
                nickname: '乖乖',
                content: entry.diaryGuaiGuai!,
                expandable: !compact,
              ),
            if (entry.diaryJingJing != null)
              _DiaryRow(
                nickname: '晶晶',
                content: entry.diaryJingJing!,
                expandable: !compact,
              ),
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

/// 日记行：默认截断显示摘要。
/// [expandable] 为 true 时点击可展开/收起完整日记；false 时始终只显示摘要。
class _DiaryRow extends StatefulWidget {
  final String nickname;
  final String content;
  final bool expandable;

  const _DiaryRow({
    required this.nickname,
    required this.content,
    this.expandable = true,
  });

  @override
  State<_DiaryRow> createState() => _DiaryRowState();
}

class _DiaryRowState extends State<_DiaryRow> {
  static const int _summaryChars = 80;
  bool _expanded = false;

  bool get _truncated => widget.content.length > _summaryChars;

  String get _displayText {
    final c = widget.content;
    if (!widget.expandable) {
      return _truncated ? '${c.substring(0, _summaryChars)}…' : c;
    }
    if (!_truncated || _expanded) return c;
    return '${c.substring(0, _summaryChars)}…';
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              widget.nickname,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: widget.expandable && _truncated ? _toggle : null,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '"$_displayText"',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (_truncated && widget.expandable)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Text(
                              _expanded ? '收起' : '查看全文',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Icon(
                              _expanded ? Icons.expand_less : Icons.expand_more,
                              size: 14,
                              color: colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
