import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/travel_record.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class TravelDateDetails extends StatelessWidget {
  const TravelDateDetails({
    super.key,
    required this.date,
    required this.record,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    this.enabled = true,
  });

  final DateTime date;
  final TravelRecord? record;
  final VoidCallback onAdd;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final entry = record;

    Widget detail(IconData icon, String label, String value) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: AppSpacing.xl, color: scheme.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: AppText.caption
                          .copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(value, style: AppText.body),
                ],
              ),
            ),
          ],
        );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.cardComfortable,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(DateFormat('yyyy年M月d日').format(date),
                style: AppText.pageTitle),
            const SizedBox(height: AppSpacing.xs),
            Text(
                '${weekdays[date.weekday - 1]} · ${entry == null ? '暂无记录' : '出行记录'}',
                style:
                    AppText.caption.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.xl),
            if (entry != null) ...[
              detail(Icons.place_outlined, '地点', entry.location),
              const SizedBox(height: AppSpacing.lg),
              detail(Icons.event_note_outlined, '事件',
                  entry.event.isEmpty ? '未填写' : entry.event),
              const SizedBox(height: AppSpacing.xl),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: enabled ? onEdit : null,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('编辑记录'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  IconButton(
                    tooltip: '删除记录',
                    onPressed: enabled ? onDelete : null,
                    style: IconButton.styleFrom(
                      foregroundColor: scheme.error,
                      backgroundColor:
                          context.wallpaperFill(scheme.errorContainer),
                    ),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ] else ...[
              Text('这一天还没有出行记录',
                  style: AppText.body.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: enabled ? onAdd : null,
                  icon: const Icon(Icons.add),
                  label: const Text('新增当天记录'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
