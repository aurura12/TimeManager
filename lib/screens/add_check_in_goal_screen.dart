import 'package:flutter/material.dart';

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

  static const _themeColors = [
    Color(0xFFF16B77),
    Color(0xFFF98E45),
    Color(0xFFD9BD2E),
    Color(0xFF96B462),
    Color(0xFF4DA8EE),
    Color(0xFF9575CD),
    Color(0xFFE91E63),
  ];

  static const _icons = [
    Icons.directions_run,
    Icons.fitness_center,
    Icons.menu_book,
    Icons.self_improvement,
    Icons.pool,
    Icons.pedal_bike,
    Icons.nightlight,
    Icons.restaurant,
    Icons.work,
    Icons.pets,
  ];

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
}
