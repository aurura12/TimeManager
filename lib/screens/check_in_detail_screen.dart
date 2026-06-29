import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';

import '../models/check_in_goal.dart';
import '../models/check_in_record.dart';
import '../services/check_in_sync_service.dart';
import '../widgets/check_in_map_preview.dart';
import '../widgets/check_in_photo_sheet.dart';
import '../widgets/check_in_photo_thumb.dart';
import '../widgets/check_in_photo_viewer.dart';
import 'add_check_in_goal_screen.dart';

class CheckInDetailScreen extends StatefulWidget {
  const CheckInDetailScreen({
    super.key,
    required this.goal,
    required this.syncService,
  });

  final CheckInGoal goal;
  final CheckInSyncService syncService;

  @override
  State<CheckInDetailScreen> createState() => _CheckInDetailScreenState();
}

class _CheckInDetailScreenState extends State<CheckInDetailScreen> {
  late CheckInGoal _goal;

  @override
  void initState() {
    super.initState();
    _goal = widget.goal;
    _refreshGoalFromSync();
  }

  void _refreshGoalFromSync() {
    final updated = widget.syncService.goalsWithRecords
        .where((g) => g.id == _goal.id)
        .firstOrNull;
    if (updated != null) _goal = updated;
  }

  String? get _userId => widget.syncService.currentUser?.id;
  bool get _isMine => _userId != null && _goal.isOwnedBy(_userId!);

  Future<void> _checkIn() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          CheckInPhotoSheet(goal: _goal, syncService: widget.syncService),
    );
    if (ok == true && mounted) {
      _refreshGoalFromSync();
      setState(() {});
    }
  }

  Future<void> _edit() async {
    if (!_isMine) return;
    final result = await Navigator.push<CheckInGoal>(
      context,
      MaterialPageRoute(
        builder: (_) => AddCheckInGoalScreen(goal: _goal),
      ),
    );
    if (result == null) return;
    final saveResult = await widget.syncService.saveGoal(result);
    if (!mounted) return;
    _refreshGoalFromSync();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(saveResult.success ? '已保存' : (saveResult.error ?? '保存失败')),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    if (!_isMine) return;
    final recordCount = _goal.records.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除打卡目标'),
        content: Text(
          recordCount > 0
              ? '确认删除「${_goal.name}」吗？\n'
                  '该目标下的 $recordCount 条打卡记录也会一并删除。'
              : '确认删除「${_goal.name}」吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await widget.syncService.deleteGoal(_goal);
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除「${_goal.name}」')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? '删除失败')),
      );
    }
  }

  Future<void> _confirmDeleteRecord(CheckInRecord record) async {
    final userId = _userId;
    if (userId == null || record.userId != userId) return;

    final dateStr = DateFormat('M月d日 HH:mm').format(record.timestamp);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除打卡记录'),
        content: Text('确认删除 $dateStr 的打卡记录吗？\n此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await widget.syncService.deleteCheckInRecord(_goal, record);
    if (!mounted) return;
    if (result.success) {
      _refreshGoalFromSync();
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除打卡记录')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? '删除失败')),
      );
    }
  }

  Future<void> _archive() async {
    if (!_isMine) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('归档目标'),
        content: Text('确认归档「${_goal.name}」吗？\n归档后将从主列表隐藏，可在归档页面查看。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final updated = _goal.copyWith(
      isArchived: true,
      archivedAt: DateTime.now(),
    );
    final result = await widget.syncService.saveGoal(updated);
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已归档「${_goal.name}」')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? '归档失败')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final onColor =
        ThemeData.estimateBrightnessForColor(_goal.color) == Brightness.dark
            ? Colors.white
            : Colors.black87;
    final sortedRecords = [..._goal.records]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final statsUserId = _isMine ? _userId : _goal.ownerId;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 180,
            pinned: true,
            backgroundColor: _goal.color,
            foregroundColor: onColor,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(_goal.name),
              background: Container(
                color: _goal.color,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 40),
                    Icon(_goal.icon, size: 48, color: onColor),
                    const SizedBox(height: 8),
                    Text(
                      _isMine ? _goal.description : '${_goal.ownerLabel} 的目标',
                      style: TextStyle(
                        fontSize: 13,
                        color: onColor.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (_isMine) ...[
                if (!_goal.isArchived)
                  IconButton(icon: const Icon(Icons.edit), onPressed: _edit),
                IconButton(
                  icon: const Icon(Icons.archive_outlined),
                  onPressed: _archive,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _confirmDelete,
                ),
              ],
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          icon: Icons.check_circle_outline,
                          label: '本周期',
                          value:
                              '${_goal.currentPeriodCountFor(statsUserId)}/${_goal.targetCount}',
                          color: _goal.color,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatCard(
                          icon: Icons.local_fire_department,
                          label: '连续天数',
                          value: '${_goal.streakDaysFor(statsUserId ?? _goal.ownerId)}',
                          color: const Color(0xFFF98E45),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatCard(
                          icon: Icons.history,
                          label: '累计',
                          value: '${sortedRecords.length}',
                          color: const Color(0xFF4DA8EE),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text('打卡地图',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface)),
                  const SizedBox(height: 8),
                  CheckInMapPreview(records: _goal.records, height: 200),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('打卡记录',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface)),
                      Text('共 ${sortedRecords.length} 条',
                          style: TextStyle(
                              fontSize: 13,
                              color: colorScheme.onSurfaceVariant)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (sortedRecords.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text('还没有打卡记录',
                            style:
                                TextStyle(color: colorScheme.onSurfaceVariant)),
                      ),
                    )
                  else
                    ...sortedRecords.map(
                      (r) => _buildRecordTile(r, colorScheme),
                    ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _isMine &&
              _userId != null &&
              !_goal.isCompletedTodayBy(_userId!)
          ? FloatingActionButton.extended(
              onPressed: _checkIn,
              backgroundColor: _goal.color,
              foregroundColor: onColor,
              icon: const Icon(Icons.add_a_photo),
              label: const Text('打卡'),
            )
          : null,
    );
  }

  Widget _buildRecordTile(CheckInRecord record, ColorScheme colorScheme) {
    final dateStr = DateFormat('M月d日 HH:mm').format(record.timestamp);
    final isMe = _userId != null && record.userId == _userId;
    final hasPhoto = record.photoPath != null && record.photoPath!.isNotEmpty;

    final tile = Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: hasPhoto
            ? () => CheckInPhotoViewer.show(
                  context,
                  syncService: widget.syncService,
                  record: record,
                  isMine: isMe,
                  onDelete: isMe ? () => _confirmDeleteRecord(record) : null,
                )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CheckInPhotoThumb(
                syncService: widget.syncService,
                photoPath: record.photoPath,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(dateStr,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14)),
                        const SizedBox(width: 8),
                        Icon(Icons.check_circle,
                            size: 16, color: colorScheme.primary),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isMe ? '我' : record.userLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (record.locationName != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.location_on,
                              size: 13, color: colorScheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(record.locationName!,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ],
                    if (hasPhoto) ...[
                      const SizedBox(height: 6),
                      Text(
                        '点击查看大图',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (hasPhoto)
                Icon(Icons.chevron_right,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );

    if (!isMe) return tile;

    return Slidable(
      key: ValueKey(record.id),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.25,
        children: [
          SlidableAction(
            onPressed: (_) => _confirmDeleteRecord(record),
            backgroundColor: const Color(0xFFFE4A49),
            foregroundColor: Colors.white,
            icon: Icons.delete,
            label: '删除',
            borderRadius: BorderRadius.circular(12),
          ),
        ],
      ),
      child: tile,
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: color)),
          Text(label,
              style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8))),
        ],
      ),
    );
  }
}
