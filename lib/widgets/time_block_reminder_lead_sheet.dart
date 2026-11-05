import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/time_block_reminder.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/keyboard_dismiss.dart';

/// 选择「提前多久提醒」：快捷档位 + 自定义输入（0–30 分钟）。
///
/// 返回 null 表示取消；否则返回选中的分钟数。
Future<int?> showTimeBlockReminderLeadSheet(
  BuildContext context, {
  required int initialMinutes,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppSurfaces.of(context).overlay,
    shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
    clipBehavior: Clip.antiAlias,
    builder: (_) => _TimeBlockReminderLeadSheet(initialMinutes: initialMinutes),
  );
}

class _TimeBlockReminderLeadSheet extends StatefulWidget {
  const _TimeBlockReminderLeadSheet({required this.initialMinutes});

  final int initialMinutes;

  @override
  State<_TimeBlockReminderLeadSheet> createState() =>
      _TimeBlockReminderLeadSheetState();
}

class _TimeBlockReminderLeadSheetState
    extends State<_TimeBlockReminderLeadSheet> {
  late final TextEditingController _controller;
  int? _selected;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = TimeBlockReminderSettings.isValidLead(widget.initialMinutes)
        ? widget.initialMinutes
        : TimeBlockReminderSettings.defaultLeadMinutes;
    final isPreset =
        TimeBlockReminderSettings.quickLeadOptions.contains(initial);
    _selected = initial;
    // 快捷档位用 chip 表达，输入框只在自定义值时带内容。
    _controller = TextEditingController(text: isPreset ? '' : '$initial');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onCustomChanged(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _selected = null;
        _error = null;
      });
      return;
    }
    final parsed = int.tryParse(trimmed);
    setState(() {
      if (parsed != null && TimeBlockReminderSettings.isValidLead(parsed)) {
        _selected = parsed;
        _error = null;
      } else {
        _selected = null;
        _error = '请输入 0–30 之间的整数';
      }
    });
  }

  void _confirm() {
    final value = _selected;
    if (value == null) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg + bottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('提前多久提醒', style: AppText.sectionTitle),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '事件开始前提醒；已经开始但还没结束的事件，会在下次打开应用时补一次。',
            style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final option in TimeBlockReminderSettings.quickLeadOptions)
                ChoiceChip(
                  label: Text(option == 0 ? '准点' : '$option 分钟'),
                  selected: _selected == option,
                  // 快捷档位直接生效，和「提前量」的其它面板保持一致。
                  onSelected: (_) => Navigator.of(context).pop(option),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 3,
            onChanged: _onCustomChanged,
            onTapOutside: dismissKeyboardOnTapOutside,
            decoration: InputDecoration(
              labelText: '自定义',
              helperText: '0–30 分钟，可填任意整数',
              errorText: _error,
              suffixText: '分钟',
              counterText: '',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: FilledButton(
                  onPressed: _selected == null ? null : _confirm,
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
