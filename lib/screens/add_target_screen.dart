import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/target.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/desktop_shortcut_host.dart';
import '../utils/platform_features.dart';

/// 桌面端原地编辑，移动端继续使用完整页面。
Future<Target?> showTargetEditor(BuildContext context, {Target? target}) {
  final provider = context.read<TimeProvider>();
  if (isDesktopPlatform) {
    return showDialog<Target>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChangeNotifierProvider<TimeProvider>.value(
        value: provider,
        child: AddTargetScreen(target: target, asDialog: true),
      ),
    );
  }
  return Navigator.of(context).push<Target>(
    MaterialPageRoute(
      builder: (_) => AddTargetScreen(target: target),
    ),
  );
}

class AddTargetScreen extends StatefulWidget {
  final Target? target; // 接收可选的目标对象用于编辑
  final bool asDialog;

  const AddTargetScreen({super.key, this.target, this.asDialog = false});

  @override
  State<AddTargetScreen> createState() => _AddTargetScreenState();
}

class _AddTargetScreenState extends State<AddTargetScreen> {
  TargetType _selectedType = TargetType.duration;
  Color _selectedColor = AppSemanticColors.palette.first;
  String _selectedPeriod = "每周";
  bool _isSaving = false;
  String? _saveError;
  final _desktopFormKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  String _periodMode = '每周';
  String _periodDaysValue = '7';

  // --- 可编辑的表单数据 ---
  String _eventName = "运动";
  String _categoryId = "";
  String _compareType = "超过";
  String _durationValue = "6"; // 仅数字部分
  String _frequencyCount = "3";
  String _targetTime = "22:00";
  String _startTime = "16:00";
  String _endTime = "24:00";

  final List<Color> _themeColors = AppSemanticColors.palette;

  static const _periods = [
    '每天',
    '每周',
    '每月',
    '每年',
    '每n天',
    '今天',
    '本周',
    '一周内',
    '本月',
    '一月内',
    '今年',
    '一年内',
    'n天内',
    '起止日期',
  ];

  List<String> get _compareTypes => _selectedType == TargetType.timePoint
      ? const ['之前', '之后']
      : const ['至少', '超过', '少于', '等于'];

  @override
  void initState() {
    super.initState();
    // 如果传入了 target，则初始化表单数据（回显）
    if (widget.target != null) {
      final t = widget.target!;
      _eventName = t.name;
      _categoryId = t.categoryId;
      _selectedType = t.type;
      _selectedPeriod = t.period;
      _compareType = t.compareType;

      // 设置颜色（支持自定义颜色）
      _selectedColor = t.color;

      // 根据类型回显具体数值
      if (t.type == TargetType.duration) {
        _durationValue =
            t.durationHours.toString().replaceAll(RegExp(r'\.0$'), '');
      } else if (t.type == TargetType.frequency) {
        _frequencyCount = t.frequencyCount.toString();
      } else if (t.type == TargetType.timePoint) {
        // 旧数据可能缺字段（默认空串），保留表单默认值而不是显示空白
        if (t.targetTime.isNotEmpty) _targetTime = t.targetTime;
        if (t.startTime.isNotEmpty) _startTime = t.startTime;
        if (t.endTime.isNotEmpty) _endTime = t.endTime;
      }
    } else if (widget.asDialog) {
      final categories = context.read<TimeProvider>().categories;
      if (categories.isNotEmpty) {
        final category = categories.firstWhere(
          (category) => category.name == _eventName,
          orElse: () => categories.first,
        );
        _eventName = category.name;
        _categoryId = category.id;
      }
    }
    if (_selectedType == TargetType.timePoint) {
      // 老版本的“少于/超过”等选项分别按之前/之后判断，保留其实际语义。
      _compareType = _compareType.contains('前') || _compareType.contains('少')
          ? '之前'
          : '之后';
    } else if (!_compareTypes.contains(_compareType)) {
      _compareType = '超过';
    }
    final days = RegExp(r'^(?:每)?(\d+)天(?:内)?$').firstMatch(_selectedPeriod);
    if (days != null) {
      _periodDaysValue = days.group(1)!;
      _periodMode = _selectedPeriod.startsWith('每') ? '每n天' : 'n天内';
    } else {
      _periodMode = _selectedPeriod.contains('~') ? '起止日期' : _selectedPeriod;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _changeType(TargetType type) {
    if (_isSaving || type == _selectedType) return;
    setState(() {
      _selectedType = type;
      _compareType = type == TargetType.timePoint ? '之前' : '超过';
      if (type == TargetType.timePoint) {
        _selectedPeriod = '每天';
        _periodMode = '每天';
      }
    });
  }

  String? _positiveNumber(String? value,
      {required String label, bool integer = false}) {
    final raw = value?.trim() ?? '';
    final parsed =
        integer ? int.tryParse(raw)?.toDouble() : double.tryParse(raw);
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      return integer ? '请输入正整数$label' : '请输入大于 0 的$label';
    }
    return null;
  }

  int? _timeMinutes(String value, {bool allowDayEnd = false}) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (allowDayEnd && hour == 24 && minute == 0) return 1440;
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }

  String? _validationMessage() {
    if (_eventName.trim().isEmpty) return '请选择关联事件';
    if (_selectedType == TargetType.duration) {
      final message = _positiveNumber(_durationValue, label: '时长');
      if (message != null) return message;
    } else if (_selectedType == TargetType.frequency) {
      final message =
          _positiveNumber(_frequencyCount, label: '次数', integer: true);
      if (message != null) return message;
    } else {
      if (_timeMinutes(_targetTime) == null) return '请输入有效的目标时间（HH:mm）';
      final start = _timeMinutes(_startTime);
      final end = _timeMinutes(_endTime, allowDayEnd: true);
      if (start == null || end == null || start >= end) {
        return '有效时间区间的结束时间必须晚于开始时间';
      }
    }
    if (_selectedType != TargetType.timePoint &&
        (_periodMode == '每n天' || _periodMode == 'n天内')) {
      return _positiveNumber(_periodDaysValue, label: '天数', integer: true);
    }
    if (_selectedType != TargetType.timePoint &&
        _periodMode == '起止日期' &&
        !_selectedPeriod.contains('~')) {
      return '请选择起止日期';
    }
    return null;
  }

  // --- 辅助方法：显示输入弹窗 ---
  Future<void> _showInputDialog(
      String title, String currentValue, Function(String) onSave,
      {bool isNumber = false}) async {
    var inputValue = currentValue;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("设置$title"),
        content: TextFormField(
          initialValue: currentValue,
          autofocus: true,
          onChanged: (value) => inputValue = value,
          keyboardType: isNumber ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(hintText: "请输入$title"),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
            onPressed: () {
              final error = isNumber
                  ? _positiveNumber(inputValue,
                      label: title == '时长(小时)' ? '时长' : title,
                      integer: title != '时长(小时)')
                  : (inputValue.trim().isEmpty ? '请输入$title' : null);
              if (error != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(error)),
                );
              } else {
                onSave(inputValue.trim());
                Navigator.pop(context);
                setState(() {});
              }
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  /// 把 "HH:mm" 字符串安全地转成 TimeOfDay。
  ///
  /// - "24:00" 这类当天结束边界按 00:00 展示（TimeOfDay 不接受 hour=24）
  /// - 空串、非法字符、越界数值一律回退到 [fallback]，不抛异常
  TimeOfDay _parseTimeOfDay(String value,
      {TimeOfDay fallback = const TimeOfDay(hour: 0, minute: 0)}) {
    final parts = value.split(':');
    if (parts.length < 2) return fallback;
    final hour = int.tryParse(parts[0].trim());
    final minute = int.tryParse(parts[1].trim());
    if (hour == null || minute == null) return fallback;
    if (hour == 24 && minute == 0) return const TimeOfDay(hour: 0, minute: 0);
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return fallback;
    return TimeOfDay(hour: hour, minute: minute);
  }

  Future<void> _pickTime(String initialTime, Function(String) onSave) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _parseTimeOfDay(initialTime),
    );
    if (picked != null && mounted) {
      setState(() {
        onSave(
            "${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}");
      });
    }
  }

  // --- 辅助方法：事件选择弹窗 ---
  void _showEventSelectionDialog() {
    final provider = Provider.of<TimeProvider>(context, listen: false);
    showDialog(
      context: context,
      builder: (context) {
        final dialogSurface = AppSurfaces.of(context).card;
        return AlertDialog(
          title: const Text("选择事件"),
          content: SizedBox(
            width: double.maxFinite,
            child: provider.categories.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text("暂无已有事件，请先在首页添加"),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: provider.categories.length,
                    itemBuilder: (context, index) {
                      final category = provider.categories[index];
                      final chipBg = AppSemanticColors.tint(
                          category.color, dialogSurface, 0.2);
                      final chipFg = AppSemanticColors.onTint(
                          category.color, dialogSurface,
                          alpha: 0.2);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor: category.color,
                              radius: 8,
                            ),
                            title: Text(category.name),
                            onTap: () {
                              setState(() {
                                _eventName = category.name;
                                _categoryId = category.id;
                              });
                              Navigator.pop(context);
                            },
                          ),
                          if (category.subCategories.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 56.0, bottom: 8.0),
                              child: Wrap(
                                spacing: 8.0,
                                runSpacing: 4.0,
                                children: category.subCategories.map((sub) {
                                  return ActionChip(
                                    label: Text(sub,
                                        style: TextStyle(
                                            fontSize: 12, color: chipFg)),
                                    backgroundColor: chipBg,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      setState(() {
                                        _eventName = sub;
                                        _categoryId = category.id;
                                      });
                                      Navigator.pop(context);
                                    },
                                  );
                                }).toList(),
                              ),
                            ),
                          const Divider(height: 1),
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveTarget() async {
    if (_isSaving) return;
    if (widget.asDialog &&
        !(_desktopFormKey.currentState?.validate() ?? false)) {
      return;
    }
    final validation = _validationMessage();
    if (validation != null) {
      if (widget.asDialog) {
        setState(() => _saveError = validation);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(validation)));
      }
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    final provider = Provider.of<TimeProvider>(context, listen: false);
    final categoryId = _categoryId.isNotEmpty
        ? _categoryId
        : (provider.resolveCategoryIdForLabel(_eventName) ?? '');
    final newTarget = Target(
      id: widget.target?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: _eventName,
      categoryId: categoryId,
      type: _selectedType,
      color: _selectedColor,
      period: _selectedPeriod,
      compareType: _compareType,
      durationHours: double.tryParse(_durationValue.trim()) ?? 0,
      frequencyCount: int.tryParse(_frequencyCount.trim()) ?? 0,
      targetTime: _targetTime.trim(),
      startTime: _startTime.trim(),
      endTime: _endTime.trim(),
    );

    if (widget.target != null) {
      final saved = await provider.updateTarget(newTarget);
      if (!mounted) return;
      if (!saved) {
        setState(() {
          _isSaving = false;
          _saveError = '保存失败，请稍后重试';
        });
        if (!widget.asDialog) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('保存失败，请稍后重试')),
          );
        }
        return;
      }
    } else {
      provider.addTarget(newTarget);
    }

    if (!mounted) return;
    Navigator.pop(context, newTarget);
  }

  void _closeEditor() {
    if (!_isSaving) Navigator.of(context).pop();
  }

  Widget _buildDesktopEditor() {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.xl),
      constraints: const BoxConstraints(maxWidth: AppSizes.desktopFormMaxWidth),
      clipBehavior: Clip.antiAlias,
      child: PopScope(
        canPop: !_isSaving,
        child: DesktopShortcutHost(
          onSaveForm: () => unawaited(_saveTarget()),
          onEscape: () {
            if (_isSaving) return false;
            _closeEditor();
            return true;
          },
          isAvailable: (_) => !_isSaving,
          child: FocusTraversalGroup(
            child: SizedBox(
              width: AppSizes.desktopFormMaxWidth,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom -
                      AppSpacing.xl * 2,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.xl,
                          AppSpacing.md, AppSpacing.md, AppSpacing.md),
                      child: Row(children: [
                        Expanded(
                            child: Text(widget.target == null ? '新建目标' : '编辑目标',
                                style: AppText.pageTitle)),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: _isSaving ? null : _closeEditor,
                          icon: const Icon(Icons.close),
                        ),
                      ]),
                    ),
                    const Divider(height: AppSizes.hairline),
                    Flexible(
                      child: Scrollbar(
                        controller: _scrollController,
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context)
                              .copyWith(scrollbars: false),
                          child: SingleChildScrollView(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            child: Form(
                              key: _desktopFormKey,
                              autovalidateMode:
                                  AutovalidateMode.onUserInteraction,
                              child: _buildDesktopFields(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: AppSizes.hairline),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_saveError != null) ...[
                            Text(_saveError!,
                                style:
                                    AppText.body.copyWith(color: scheme.error)),
                            const SizedBox(height: AppSpacing.md),
                          ],
                          Row(children: [
                            Expanded(
                                child: Text(
                                    desktopShortcutLabel(
                                                context,
                                                DesktopShortcutActionType
                                                    .saveForm)
                                            .isEmpty
                                        ? '点击保存提交'
                                        : '${desktopShortcutLabel(context, DesktopShortcutActionType.saveForm)} 保存',
                                    style: AppText.caption.copyWith(
                                        color: scheme.onSurfaceVariant))),
                            TextButton(
                              onPressed: _isSaving ? null : _closeEditor,
                              child: const Text('取消'),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            FilledButton(
                              onPressed: _isSaving ? null : _saveTarget,
                              child: Text(_isSaving ? '保存中…' : '保存'),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopFields() {
    final scheme = Theme.of(context).colorScheme;
    final provider = context.read<TimeProvider>();
    final events = <(String, String), String>{};
    for (final category in provider.categories) {
      events[(category.id, category.name)] = category.name;
      for (final sub in category.subCategories) {
        events[(category.id, sub)] = '${category.name} / $sub';
      }
    }
    final selectedEvent = (_categoryId, _eventName);
    if (widget.target != null && !events.containsKey(selectedEvent)) {
      // 历史目标可以关联已删除的事件，编辑其他字段时保留该关联。
      events[selectedEvent] = '$_eventName（原关联事件）';
    }

    final type = DropdownButtonFormField<TargetType>(
      key: const ValueKey('target_type'),
      initialValue: _selectedType,
      decoration: const InputDecoration(labelText: '目标类型'),
      isExpanded: true,
      items: [
        for (final type in TargetType.values)
          DropdownMenuItem(value: type, child: Text(_getTypeName(type))),
      ],
      onChanged: _isSaving
          ? null
          : (value) {
              if (value != null) _changeType(value);
            },
    );
    final comparison = DropdownButtonFormField<String>(
      key: const ValueKey('target_comparison'),
      initialValue: _compareType,
      decoration: const InputDecoration(labelText: '比较条件'),
      items: [
        for (final comparison in _compareTypes)
          DropdownMenuItem(value: comparison, child: Text(comparison)),
      ],
      onChanged: _isSaving
          ? null
          : (value) {
              if (value != null) setState(() => _compareType = value);
            },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<(String, String)>(
          key: const ValueKey('target_event'),
          initialValue:
              events.containsKey(selectedEvent) ? selectedEvent : null,
          isExpanded: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: '关联事件'),
          hint: const Text('请选择已有事件'),
          items: [
            for (final entry in events.entries)
              DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value, overflow: TextOverflow.ellipsis)),
          ],
          validator: (value) => value == null ? '请选择关联事件' : null,
          onChanged: _isSaving
              ? null
              : (value) {
                  if (value != null) {
                    setState(() {
                      _categoryId = value.$1;
                      _eventName = value.$2;
                    });
                  }
                },
        ),
        if (events.isEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('暂无已有事件，请先在记录页添加事件',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: AppSpacing.lg),
        _formPair(type, comparison),
        const SizedBox(height: AppSpacing.lg),
        if (_selectedType == TargetType.timePoint) ...[
          _timeField('目标时间', _targetTime,
              (value) => setState(() => _targetTime = value)),
          const SizedBox(height: AppSpacing.lg),
          _formPair(
            _timeField('区间开始', _startTime,
                (value) => setState(() => _startTime = value)),
            _timeField(
                '区间结束', _endTime, (value) => setState(() => _endTime = value),
                allowDayEnd: true),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('每天判断区间内的首次记录；当天结束可填写 24:00',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant)),
        ] else ...[
          _formPair(
            TextFormField(
              key: ValueKey(_selectedType == TargetType.duration
                  ? 'target_duration'
                  : 'target_frequency'),
              initialValue: _selectedType == TargetType.duration
                  ? _durationValue
                  : _frequencyCount,
              enabled: !_isSaving,
              keyboardType: TextInputType.numberWithOptions(
                  decimal: _selectedType == TargetType.duration),
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText:
                    _selectedType == TargetType.duration ? '目标时长' : '目标次数',
                suffixText: _selectedType == TargetType.duration ? '小时' : '次',
              ),
              validator: (value) => _positiveNumber(value,
                  label: _selectedType == TargetType.duration ? '时长' : '次数',
                  integer: _selectedType == TargetType.frequency),
              onChanged: (value) => setState(() {
                if (_selectedType == TargetType.duration) {
                  _durationValue = value;
                } else {
                  _frequencyCount = value;
                }
              }),
            ),
            DropdownButtonFormField<String>(
              key: const ValueKey('target_period'),
              initialValue: _periodMode,
              decoration: const InputDecoration(labelText: '目标周期'),
              isExpanded: true,
              items: [
                for (final period in {
                  ..._periods,
                  if (!_periods.contains(_periodMode)) _periodMode,
                })
                  DropdownMenuItem(
                      value: period,
                      child: Text(period == '每n天'
                          ? '每 N 天'
                          : period == 'n天内'
                              ? 'N 天内'
                              : period)),
              ],
              onChanged: _isSaving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _periodMode = value;
                        _selectedPeriod = value.contains('n')
                            ? value.replaceAll('n', _periodDaysValue)
                            : value;
                      });
                    },
            ),
          ),
          if (_periodMode == '每n天' || _periodMode == 'n天内') ...[
            const SizedBox(height: AppSpacing.lg),
            TextFormField(
              key: const ValueKey('target_period_days'),
              initialValue: _periodDaysValue,
              enabled: !_isSaving,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              decoration:
                  const InputDecoration(labelText: '周期天数', suffixText: '天'),
              validator: (value) =>
                  _positiveNumber(value, label: '天数', integer: true),
              onChanged: (value) => setState(() {
                _periodDaysValue = value.trim();
                _selectedPeriod = _periodMode.replaceAll('n', _periodDaysValue);
              }),
            ),
          ],
          if (_periodMode == '起止日期') ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _isSaving ? null : _pickDesktopDateRange,
                icon: const Icon(Icons.date_range_outlined),
                label: Text(
                    _selectedPeriod.contains('~') ? _selectedPeriod : '选择起止日期'),
              ),
            ),
          ],
        ],
        const SizedBox(height: AppSpacing.xl),
        const Text('目标颜色', style: AppText.sectionTitle),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            for (var i = 0; i < _themeColors.length; i++)
              Tooltip(
                message: '颜色 ${i + 1}',
                child: Semantics(
                  button: true,
                  selected: _selectedColor == _themeColors[i],
                  child: InkWell(
                    borderRadius: AppRadius.controlAll,
                    onTap: _isSaving
                        ? null
                        : () =>
                            setState(() => _selectedColor = _themeColors[i]),
                    child: SizedBox(
                      width: AppSizes.minTapTarget,
                      height: AppSizes.minTapTarget,
                      child: Center(
                        child: CircleAvatar(
                          radius: AppSizes.chip / 2,
                          backgroundColor:
                              context.adaptSemanticFill(_themeColors[i]),
                          child: _selectedColor == _themeColors[i]
                              ? Icon(Icons.check,
                                  size: AppSpacing.lg,
                                  color: AppSemanticColors.onColor(context
                                      .adaptSemanticColor(_themeColors[i])))
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: AppSpacing.cardComfortable,
          decoration: BoxDecoration(
            color: context.wallpaperFill(AppSurfaces.of(context).subtle),
            borderRadius: AppRadius.controlAll,
          ),
          child: Text(
              '${_selectedType == TargetType.timePoint ? '每天' : _selectedPeriod} · ${_getPreviewText()}',
              style: AppText.body),
        ),
      ],
    );
  }

  Widget _formPair(Widget first, Widget second) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < AppSizes.dialogMaxWidth) {
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: AppSpacing.lg),
              second,
            ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: first),
        const SizedBox(width: AppSpacing.lg),
        Expanded(child: second),
      ]);
    });
  }

  Widget _timeField(String label, String value, ValueChanged<String> onChanged,
      {bool allowDayEnd = false}) {
    return TextFormField(
      key: ValueKey(label),
      initialValue: value,
      enabled: !_isSaving,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: label, hintText: 'HH:mm'),
      validator: (raw) =>
          _timeMinutes(raw ?? '', allowDayEnd: allowDayEnd) == null
              ? '请输入有效时间（HH:mm）'
              : null,
      onChanged: onChanged,
    );
  }

  Future<void> _pickDesktopDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    String format(DateTime date) =>
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    setState(() =>
        _selectedPeriod = '${format(picked.start)}~${format(picked.end)}');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.asDialog) return _buildDesktopEditor();
    final colorScheme = Theme.of(context).colorScheme;
    Color activeColor = _selectedColor;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 80,
        leading: TextButton(
          onPressed: _isSaving ? null : _saveTarget,
          style: TextButton.styleFrom(
            foregroundColor: colorScheme.onSurface,
          ),
          child: const Text("确定", style: TextStyle(fontSize: 16)),
        ),
        title: Text(widget.target != null ? "编辑计划" : "制定计划"),
        centerTitle: true,
        actions: [
          PopupMenuButton<TargetType>(
            initialValue: _selectedType,
            onSelected: (TargetType type) {
              _changeType(type);
            },
            child: Row(
              children: [
                Text(_getTypeName(_selectedType),
                    style: TextStyle(
                      color: colorScheme.onSurface,
                    )),
                Icon(
                  Icons.arrow_drop_down,
                  color: colorScheme.onSurface,
                ),
                const SizedBox(width: 10),
              ],
            ),
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: TargetType.duration, child: Text("时长目标")),
              const PopupMenuItem(
                  value: TargetType.timePoint, child: Text("时间点目标")),
              const PopupMenuItem(
                  value: TargetType.frequency, child: Text("次数目标")),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 预览卡片
            _buildPreviewCard(activeColor),
            // 2. 颜色选择器
            _buildColorPicker(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                "点击下方按钮制定计划",
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            // 3. 周期选择
            if (_selectedType != TargetType.timePoint) ...[
              _buildSectionTitle("周期:"),
              _buildPeriodGrid(),
            ],
            const SizedBox(height: 20),
            _buildSectionTitle("计划内容:"),
            // 4. 表单内容
            _buildTargetContentForm(),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewCard(Color activeColor) {
    final cardColor = context.adaptSemanticColor(activeColor);
    final cardFill = context.adaptSemanticFill(activeColor);
    final onCardColor = AppSemanticColors.onColor(cardColor);

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      width: double.infinity,
      decoration:
          BoxDecoration(color: cardFill, borderRadius: AppRadius.controlAll),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selectedType != TargetType.timePoint)
            Text(_selectedPeriod,
                style: TextStyle(color: onCardColor.withValues(alpha: 0.75))),
          const SizedBox(height: 8),
          Text(_getPreviewText(),
              style: TextStyle(
                  color: onCardColor,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildTargetContentForm() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        // 【关键修复】：显式设置内部列的所有组件从左侧开始排列
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFormRow("事件名称", _eventName, () => _showEventSelectionDialog()),
          Row(
            children: [
              SizedBox(
                width: AppSizes.iconButton * 2,
                child: Text('比较类型',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              DropdownButton<String>(
                value: _compareType,
                items: [
                  for (final type in _compareTypes)
                    DropdownMenuItem(value: type, child: Text(type)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _compareType = value);
                },
              ),
            ],
          ),
          if (_selectedType == TargetType.duration)
            _buildFormRow(
                "事件时长",
                "$_durationValue小时",
                () => _showInputDialog(
                    "时长(小时)", _durationValue, (v) => _durationValue = v,
                    isNumber: true)),
          if (_selectedType == TargetType.frequency)
            _buildFormRow(
                "比较次数",
                _frequencyCount,
                () => _showInputDialog(
                    "次数", _frequencyCount, (v) => _frequencyCount = v,
                    isNumber: true)),
          if (_selectedType == TargetType.timePoint) ...[
            _buildFormRow("比较时间", _targetTime,
                () => _pickTime(_targetTime, (v) => _targetTime = v)),
            const SizedBox(height: 10),
            // 现在这个 Text 会受到上面 crossAxisAlignment.start 的影响而居左
            const Text("有效时间区间:", style: TextStyle(fontSize: 16)),
            const SizedBox(height: 10),
            Row(
              // 同时也确保这个 Row 内部的按钮也是从左开始
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                _buildSmallBtn(_startTime,
                    () => _pickTime(_startTime, (v) => _startTime = v)),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text("~")),
                _buildSmallBtn(
                    _endTime, () => _pickTime(_endTime, (v) => _endTime = v)),
              ],
            )
          ]
        ],
      ),
    );
  }

  // --- 基础组件封装 ---

  Widget _buildFormRow(String label, String value, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
              width: 80,
              child: Text(label,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant))),
          _buildSmallBtn(value, onTap),
        ],
      ),
    );
  }

  Widget _buildSmallBtn(String text, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: AppRadius.badgeAll),
        child: Text(
          text,
          style: TextStyle(color: colorScheme.onPrimaryContainer),
        ),
      ),
    );
  }

  String _getPreviewText() {
    switch (_selectedType) {
      case TargetType.duration:
        return "$_eventName$_compareType$_durationValue小时";
      case TargetType.timePoint:
        return "$_targetTime$_compareType$_eventName";
      case TargetType.frequency:
        return "$_eventName$_compareType$_frequencyCount次";
    }
  }

  String _getTypeName(TargetType type) {
    switch (type) {
      case TargetType.duration:
        return "时长目标";
      case TargetType.timePoint:
        return "时间点目标";
      case TargetType.frequency:
        return "次数目标";
    }
  }

  Widget _buildSectionTitle(String title, {double padding = 16}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padding, vertical: 8),
      child: Text(title, style: const TextStyle(fontSize: 16)),
    );
  }

  Widget _buildColorPicker() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(_themeColors.length, (index) {
          return GestureDetector(
            onTap: () => setState(() => _selectedColor = _themeColors[index]),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: _themeColors[index].withValues(alpha: 0.3),
              child: CircleAvatar(
                radius: 14,
                backgroundColor: _themeColors[index],
                child: _selectedColor == _themeColors[index]
                    ? Icon(Icons.check,
                        size: 16,
                        color: AppSemanticColors.onColor(_themeColors[index]))
                    : null,
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildPeriodGrid() {
    return Padding(
      // ----- 弹窗输入天数 -----
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _periods
            .map((p) => ChoiceChip(
                  label: Text(p),
                  selected: _periodMode == p,
                  onSelected: (val) async {
                    if (p == "每n天" || p == "n天内") {
                      _showInputDialog("天数", _periodDaysValue, (v) {
                        setState(() {
                          _selectedPeriod = p.replaceAll('n', v);
                          _periodMode = p;
                          _periodDaysValue = v;
                        });
                      }, isNumber: true);
                    } else if (p == "起止日期") {
                      final DateTimeRange? picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setState(() {
                          String start =
                              "${picked.start.year}-${picked.start.month.toString().padLeft(2, '0')}-${picked.start.day.toString().padLeft(2, '0')}";
                          String end =
                              "${picked.end.year}-${picked.end.month.toString().padLeft(2, '0')}-${picked.end.day.toString().padLeft(2, '0')}";
                          _selectedPeriod = "$start~$end";
                          _periodMode = p;
                        });
                      }
                    } else {
                      setState(() {
                        _selectedPeriod = p;
                        _periodMode = p;
                      });
                    }
                  },
                ))
            .toList(),
      ),
    );
  }
}
