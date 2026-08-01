import 'package:flutter/material.dart';

import '../models/on_this_day_entry.dart';
import 'on_this_day_year_card.dart';

/// 打开"那年今日"底部弹窗
///
/// [onShown]：弹窗完成入场动画后回调，用于"真正显示后再落盘"。
Future<void> showOnThisDaySheet(
  BuildContext context, {
  required List<OnThisDayEntry> entries,
  required int month,
  required int day,
  VoidCallback? onShown,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _OnThisDayContent(
      entries: entries,
      month: month,
      day: day,
      onShown: onShown,
    ),
  );
}

class _OnThisDayContent extends StatelessWidget {
  final List<OnThisDayEntry> entries;
  final int month;
  final int day;
  final VoidCallback? onShown;

  const _OnThisDayContent({
    required this.entries,
    required this.month,
    required this.day,
    this.onShown,
  });

  String get _dateLabel => '$month月$day日';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

    // 弹窗完成入场动画后触发 onShown（真正显示才标记已弹）
    if (onShown != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onShown?.call();
      });
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  Text(
                    '📅',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '那年今日 · $_dateLabel',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '过去的今天，你们在做什么',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                shrinkWrap: true,
                children: [
                  for (final entry in entries) OnThisDayYearCard(entry: entry),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
