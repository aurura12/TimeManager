import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/check_in_goal.dart';

class AddCheckInGoalScreen extends StatefulWidget {
  const AddCheckInGoalScreen({super.key, this.goal});

  final CheckInGoal? goal;

  @override
  State<AddCheckInGoalScreen> createState() => _AddCheckInGoalScreenState();
}

class _AddCheckInGoalScreenState extends State<AddCheckInGoalScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _countController = TextEditingController(text: '1');

  int _selectedColorIndex = 3;
  int _selectedIconIndex = 0;
  CheckInPeriod _period = CheckInPeriod.daily;
  bool _requireLocation = true;
  bool _requirePhoto = true;
  DateTime? _startDate;
  DateTime? _endDate;
  int? _selectedDurationDays;

  static const _themeColors = [
    Color(0xFFF16B77),
    Color(0xFFF98E45),
    Color(0xFFD9BD2E),
    Color(0xFF96B462),
    Color(0xFF4DA8EE),
    Color(0xFF9575CD),
    Color(0xFFE91E63),
  ];

  static const _icons = CheckInGoalIcons.options;

  static const _durationOptions = [
    _DurationOption(label: '1周', days: 7),
    _DurationOption(label: '2周', days: 14),
    _DurationOption(label: '1个月', days: 30),
    _DurationOption(label: '2个月', days: 60),
    _DurationOption(label: '3个月', days: 90),
    _DurationOption(label: '6个月', days: 180),
    _DurationOption(label: '1年', days: 365),
  ];

  void _onDurationSelected(int? days) {
    setState(() {
      _selectedDurationDays = days;
      if (days != null && _startDate != null) {
        _endDate = _startDate!.add(Duration(days: days));
      }
    });
  }

  void _onStartDateChanged(DateTime? date) {
    setState(() {
      _startDate = date;
      if (date != null && _selectedDurationDays != null) {
        _endDate = date.add(Duration(days: _selectedDurationDays!));
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.goal != null) {
      final g = widget.goal!;
      _nameController.text = g.name;
      _descController.text = g.description;
      _countController.text = g.targetCount.toString();
      _period = g.period;
      _requireLocation = g.requireLocation;
      _requirePhoto = g.requirePhoto;
      _startDate = g.startDate;
      _endDate = g.endDate;
      if (_startDate != null && _endDate != null) {
        _selectedDurationDays = _endDate!.difference(_startDate!).inDays;
      }
      final ci = _themeColors.indexWhere((c) => c.toARGB32() == g.color.toARGB32());
      if (ci >= 0) _selectedColorIndex = ci;
      final ii = _icons.indexOf(g.icon);
      if (ii >= 0) _selectedIconIndex = ii;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _countController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入目标名称')),
      );
      return;
    }
    if (_startDate != null && _endDate != null && _endDate!.isBefore(_startDate!)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('结束日期不能早于开始日期')),
      );
      return;
    }
    final count = int.tryParse(_countController.text) ?? 1;
    final goal = CheckInGoal(
      id: widget.goal?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      ownerId: widget.goal?.ownerId ?? '',
      ownerEmail: widget.goal?.ownerEmail ?? '',
      ownerDisplayName: widget.goal?.ownerDisplayName,
      name: name,
      description: _descController.text.trim(),
      color: _themeColors[_selectedColorIndex],
      icon: _icons[_selectedIconIndex],
      period: _period,
      targetCount: count.clamp(1, 99),
      records: widget.goal?.records ?? [],
      requireLocation: _requireLocation,
      requirePhoto: _requirePhoto,
      startDate: _startDate,
      endDate: _endDate,
      isArchived: widget.goal?.isArchived ?? false,
      archivedAt: widget.goal?.archivedAt,
    );
    Navigator.pop(context, goal);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEdit = widget.goal != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? '编辑打卡目标' : '新建打卡目标'),
        centerTitle: true,
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPreview(colorScheme),
          const SizedBox(height: 24),
          _sectionTitle('基本信息'),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '目标名称',
              hintText: '例如：晨跑、健身、阅读',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descController,
            decoration: const InputDecoration(
              labelText: '描述（可选）',
              hintText: '简单描述打卡要求',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 24),
          _sectionTitle('打卡周期'),
          const SizedBox(height: 8),
          SegmentedButton<CheckInPeriod>(
            segments: CheckInPeriod.values
                .map((p) => ButtonSegment(value: p, label: Text(p.label)))
                .toList(),
            selected: {_period},
            onSelectionChanged: (s) => setState(() => _period = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _countController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '${_period.label}目标次数',
              hintText: '1',
              border: const OutlineInputBorder(),
              suffixText: '次',
            ),
          ),
          const SizedBox(height: 24),
          _sectionTitle('图标'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(_icons.length, (i) {
              final selected = i == _selectedIconIndex;
              return GestureDetector(
                onTap: () => setState(() => _selectedIconIndex = i),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: selected
                        ? _themeColors[_selectedColorIndex]
                            .withValues(alpha: 0.2)
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: selected
                        ? Border.all(
                            color: _themeColors[_selectedColorIndex], width: 2)
                        : null,
                  ),
                  child: Icon(
                    _icons[i],
                    color: selected
                        ? _themeColors[_selectedColorIndex]
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 24),
          _sectionTitle('主题色'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            children: List.generate(_themeColors.length, (i) {
              final selected = i == _selectedColorIndex;
              return GestureDetector(
                onTap: () => setState(() => _selectedColorIndex = i),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _themeColors[i],
                    shape: BoxShape.circle,
                    border: selected
                        ? Border.all(color: colorScheme.onSurface, width: 2)
                        : null,
                  ),
                  child: selected
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : null,
                ),
              );
            }),
          ),
          const SizedBox(height: 24),
          _sectionTitle('打卡要求'),
          const SizedBox(height: 4),
          SwitchListTile(
            title: const Text('需要拍照'),
            subtitle: const Text('打卡时必须拍摄照片'),
            value: _requirePhoto,
            onChanged: (v) => setState(() => _requirePhoto = v),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            title: const Text('记录位置'),
            subtitle: const Text('自动获取 GPS 位置并在地图显示'),
            value: _requireLocation,
            onChanged: (v) => setState(() => _requireLocation = v),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 24),
          _sectionTitle('打卡时长（可选）'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => _pickDate(isStart: true),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: '开始日期',
                border: const OutlineInputBorder(),
                suffixIcon: _startDate != null
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => _onStartDateChanged(null),
                      )
                    : const Icon(Icons.calendar_today, size: 18),
              ),
              child: Text(
                _startDate != null
                    ? DateFormat('yyyy-MM-dd').format(_startDate!)
                    : '今天',
                style: TextStyle(
                  color: _startDate != null ? null : Colors.grey,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._durationOptions.map((opt) {
                final selected = _selectedDurationDays == opt.days;
                return ChoiceChip(
                  label: Text(opt.label),
                  selected: selected,
                  onSelected: (_) => _onDurationSelected(
                    selected ? null : opt.days,
                  ),
                );
              }),
              ChoiceChip(
                label: const Text('自定义'),
                selected: _selectedDurationDays != null &&
                    !_durationOptions.any((o) => o.days == _selectedDurationDays),
                onSelected: (_) => _showCustomDurationDialog(),
              ),
            ],
          ),
          if (_endDate != null) ...[
            const SizedBox(height: 12),
            Text(
              '结束日期：${DateFormat('yyyy-MM-dd').format(_endDate!)}',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
    );
  }

  Widget _buildPreview(ColorScheme colorScheme) {
    final color = _themeColors[_selectedColorIndex];
    final icon = _icons[_selectedIconIndex];
    final name = _nameController.text.isEmpty ? '打卡目标' : _nameController.text;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_period.label} ${_countController.text.isEmpty ? "1" : _countController.text} 次',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart
        ? (_startDate ?? DateTime.now())
        : (_endDate ?? DateTime.now().add(const Duration(days: 30)));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (picked != null && mounted) {
      if (isStart) {
        _onStartDateChanged(picked);
      } else {
        if (_startDate != null && picked.isBefore(_startDate!)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('结束日期不能早于开始日期')),
          );
          return;
        }
        setState(() {
          _endDate = picked;
          _selectedDurationDays = null;
        });
      }
    }
  }

  Future<void> _showCustomDurationDialog() async {
    final controller = TextEditingController(
      text: _selectedDurationDays?.toString() ?? '',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义天数'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '打卡天数',
            suffixText: '天',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final days = int.tryParse(controller.text);
              if (days != null && days > 0) {
                Navigator.pop(context, days);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result != null) {
      _onDurationSelected(result);
    }
  }
}

class _DurationOption {
  final String label;
  final int days;

  const _DurationOption({required this.label, required this.days});
}
