import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/category.dart';
import '../providers/time_provider.dart';
import '../services/app_identity_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/app_snack_bar.dart';
import '../utils/menu_bar_summary.dart';
import 'time_wheel_sheet.dart';

/// 菜单栏面板里的「补一段」弹层。
///
/// 只负责新增：名称、分类、起止时间。写入走
/// `TimeProvider.assignCategoryToSlots(date:)`，与主界面刷格共用一条
/// 撤销/落盘/同步链路。
Future<bool> showMenuBarEventEditor(
  BuildContext context, {
  required TimeProvider provider,
  required DateTime date,
  DateTime? now,
}) async {
  final surfaces = AppSurfaces.of(context);
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.wallpaperFill(surfaces.panel),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: AppRadius.rCard),
    ),
    builder: (_) => _MenuBarEventEditor(
      provider: provider,
      date: date,
      now: now ?? DateTime.now(),
    ),
  );
  return saved ?? false;
}

class _MenuBarEventEditor extends StatefulWidget {
  const _MenuBarEventEditor({
    required this.provider,
    required this.date,
    required this.now,
  });

  final TimeProvider provider;
  final DateTime date;
  final DateTime now;

  @override
  State<_MenuBarEventEditor> createState() => _MenuBarEventEditorState();
}

class _MenuBarEventEditorState extends State<_MenuBarEventEditor> {
  late final TextEditingController _name;
  late int _startMinute;
  late int _endMinute;
  String? _categoryId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final nowMinute = widget.now.hour * 60 + widget.now.minute;
    _startMinute = (nowMinute ~/ 10) * 10;
    _endMinute = math.min(_startMinute + 60, menuBarMinutesPerDay);
    if (_endMinute <= _startMinute) {
      _startMinute = math.max(0, menuBarMinutesPerDay - 60);
      _endMinute = menuBarMinutesPerDay;
    }
    _name = TextEditingController();
    final categories = widget.provider.categories;
    _categoryId = categories.isEmpty ? null : categories.first.id;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Category? get _selectedCategory {
    final categories = widget.provider.categories;
    for (final category in categories) {
      if (category.id == _categoryId) return category;
    }
    return categories.isEmpty ? null : categories.first;
  }

  Future<void> _pickStart() async {
    final picked = await showTimeWheelSheet(
      context,
      initialTime: TimeOfDay(hour: _startMinute ~/ 60, minute: _startMinute % 60),
      title: '开始时间',
    );
    if (picked == null || !mounted) return;
    final minute = ((picked.hour * 60 + picked.minute) ~/ 10) * 10;
    setState(() {
      _startMinute = minute;
      if (_endMinute <= _startMinute) {
        _endMinute = math.min(_startMinute + 60, menuBarMinutesPerDay);
      }
      _error = null;
    });
  }

  Future<void> _pickEnd() async {
    final picked = await showTimeWheelSheet(
      context,
      initialTime: TimeOfDay(hour: _endMinute ~/ 60, minute: _endMinute % 60),
      title: '结束时间',
    );
    if (picked == null || !mounted) return;
    final raw = picked.hour * 60 + picked.minute;
    // 结束时间向上吸附到 10 分钟，确保至少覆盖一格。
    final snapped = math.min(((raw + 9) ~/ 10) * 10, menuBarMinutesPerDay);
    setState(() {
      _endMinute = snapped;
      if (_endMinute <= _startMinute) {
        _endMinute = math.min(_startMinute + 10, menuBarMinutesPerDay);
      }
      _error = null;
    });
  }

  void _save() {
    if (_saving) return;
    final provider = widget.provider;
    final blocked = provider.scheduleEditBlockedReason;
    if (blocked != null) {
      setState(() => _error = blocked);
      return;
    }
    final category = _selectedCategory;
    if (category == null) {
      setState(() => _error = '请先在主窗口里添加分类');
      return;
    }
    if (_endMinute <= _startMinute) {
      setState(() => _error = '结束时间需要晚于开始时间');
      return;
    }
    final startIndex = _startMinute ~/ 10;
    final endIndex = _endMinute ~/ 10;
    if (startIndex < 0 || endIndex > 144 || endIndex <= startIndex) {
      setState(() => _error = '时间范围无效');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final name = _name.text.trim();
    final indices = <int>{
      for (var index = startIndex; index < endIndex; index++) index,
    };
    provider.assignCategoryToSlots(
      indices,
      category,
      subLabel: name.isEmpty ? null : name,
      date: widget.date,
    );

    final afterWriteBlocked = provider.scheduleEditBlockedReason;
    if (afterWriteBlocked != null) {
      setState(() {
        _saving = false;
        _error = afterWriteBlocked;
      });
      return;
    }

    final dateKey = provider.dateKeyFor(widget.date);
    final version = provider.editVersionOn(dateKey);
    final label = name.isEmpty ? category.name : name;
    final range = formatMenuBarRange(_startMinute, _endMinute);
    showAppUndoSnackBar(
      context,
      message: '已添加 $range $label',
      identityToken: AppIdentityService.identityStamp,
      onUndo: () async {
        if (!provider.undoLastChangeOnDate(dateKey, expectedVersion: version)) {
          throw StateError('已有新的修改，撤销已失效');
        }
      },
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final categories = provider.categories;
    final selected = _selectedCategory;
    final blocked = provider.scheduleEditBlockedReason;
    final summary = buildMenuBarSummary(
      slots: provider.slotsForDate(widget.date),
      now: widget.now,
      categories: categories,
    );
    final overlaps = summary.spans
        .where((span) =>
            span.startMinute < _endMinute && span.endMinute > _startMinute)
        .toList(growable: false);
    final canSave = !_saving && blocked == null && categories.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: AppSpacing.sheet,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('补一段', style: AppText.sectionTitle),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '事件名（可空，默认用分类名）',
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '分类',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (categories.isEmpty)
              Text(
                '还没有分类，请先在主窗口里添加',
                style: AppText.caption.copyWith(color: scheme.error),
              )
            else
              SizedBox(
                height: AppSizes.chip,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: categories.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    final isSelected = category.id == selected?.id;
                    return ChoiceChip(
                      selected: isSelected,
                      label: Text(category.name),
                      avatar: CircleAvatar(
                        backgroundColor: category.color,
                        radius: AppSizes.statusDot,
                      ),
                      onSelected: (_) =>
                          setState(() => _categoryId = category.id),
                    );
                  },
                ),
              ),
            if (selected != null && selected.subCategories.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                height: AppSizes.chip,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: selected.subCategories.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final sub = selected.subCategories[index];
                    return ActionChip(
                      label: Text(sub),
                      onPressed: () {
                        _name.text = sub;
                        setState(() => _error = null);
                      },
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _TimeField(
                    label: '开始',
                    minute: _startMinute,
                    onTap: _pickStart,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _TimeField(
                    label: '结束',
                    minute: _endMinute,
                    onTap: _pickEnd,
                  ),
                ),
              ],
            ),
            if (overlaps.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                overlaps.length == 1
                    ? '将覆盖 ${formatMenuBarRange(overlaps.first.startMinute, overlaps.first.endMinute)} 的「${overlaps.first.label}」'
                    : '将覆盖 ${overlaps.length} 段已有记录',
                style: AppText.caption.copyWith(
                  color: AppSemanticColors.readableOn(
                    AppSemanticColors.warning,
                    surfaces.card,
                  ),
                ),
              ),
            ],
            if (blocked != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                blocked,
                style: AppText.caption.copyWith(color: scheme.error),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _error!,
                style: AppText.caption.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              height: AppSizes.button,
              child: FilledButton(
                onPressed: canSave ? _save : null,
                child: Text(_saving ? '保存中…' : '保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.minute,
    required this.onTap,
  });

  final String label;
  final int minute;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final value = formatMenuBarRange(minute, minute).split('-').first;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Container(
        height: AppSizes.input,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          color: surfaces.subtle,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(value, style: AppText.body),
            const Spacer(),
            Icon(
              Icons.schedule,
              size: AppSizes.statusDot + AppSpacing.sm,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
