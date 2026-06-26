import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/check_in_goal.dart';
import '../models/check_in_record.dart';
import '../models/check_in_view_filter.dart';
import '../models/known_google_users.dart';
import '../services/check_in_sync_service.dart';
import '../widgets/check_in_map_preview.dart';

class CheckInMapScreen extends StatefulWidget {
  const CheckInMapScreen({
    super.key,
    required this.goals,
    required this.syncService,
    this.initialFilter,
  });

  final List<CheckInGoal> goals;
  final CheckInSyncService syncService;
  final CheckInViewFilter? initialFilter;

  @override
  State<CheckInMapScreen> createState() => _CheckInMapScreenState();
}

class _CheckInMapScreenState extends State<CheckInMapScreen> {
  String? _selectedGoalId;
  CheckInViewFilter _userFilter = CheckInViewFilter.all;

  @override
  void initState() {
    super.initState();
    if (widget.initialFilter != null) {
      _userFilter = widget.initialFilter!;
    }
  }

  List<CheckInRecord> get _filteredRecords {
    var records = widget.goals.expand((g) => g.records);
    if (_selectedGoalId != null) {
      records = records.where((r) => r.goalId == _selectedGoalId);
    }
    records = records.where(
      (r) => KnownGoogleUsers.matchesFilter(
        email: r.userEmail,
        filter: _userFilter,
      ),
    );
    return records.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  Map<String, int> get _locationCounts {
    final counts = <String, int>{};
    for (final r in _filteredRecords.where((r) => r.hasLocation)) {
      final key = r.locationName ?? '${r.latitude}, ${r.longitude}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sortedLocations = _locationCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final records = _filteredRecords;

    return Scaffold(
      appBar: AppBar(title: const Text('打卡地图'), centerTitle: true),
      body: Column(
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.42,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CheckInMapPreview(
                    records: records,
                    height: MediaQuery.of(context).size.height * 0.42,
                    showLegend: true,
                  ),
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildUserFilterChips(colorScheme),
                      const SizedBox(height: 8),
                      _buildGoalFilterChips(colorScheme),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '打卡地点排行',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      '${records.length} 次打卡',
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (sortedLocations.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '暂无位置数据',
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  )
                else
                  ...sortedLocations.asMap().entries.map((entry) {
                    final rank = entry.key + 1;
                    final loc = entry.value;
                    return _LocationRankTile(
                      rank: rank,
                      name: loc.key,
                      count: loc.value,
                      colorScheme: colorScheme,
                    );
                  }),
                const SizedBox(height: 16),
                Text(
                  '最近打卡',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                ...records.take(15).map((r) {
                  final goal = widget.goals.where((g) => g.id == r.goalId);
                  final g = goal.isEmpty ? null : goal.first;
                  return _RecentCheckInTile(
                    record: r,
                    goalName: g?.name ?? '未知目标',
                    goalColor: g?.color ?? colorScheme.primary,
                    colorScheme: colorScheme,
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserFilterChips(ColorScheme colorScheme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: CheckInViewFilter.values.map((filter) {
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(filter.label),
              selected: _userFilter == filter,
              onSelected: (_) => setState(() => _userFilter = filter),
              backgroundColor: colorScheme.surface.withValues(alpha: 0.92),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildGoalFilterChips(ColorScheme colorScheme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          FilterChip(
            label: const Text('全部目标'),
            selected: _selectedGoalId == null,
            onSelected: (_) => setState(() => _selectedGoalId = null),
            backgroundColor: colorScheme.surface.withValues(alpha: 0.92),
          ),
          const SizedBox(width: 8),
          ...widget.goals.map((g) {
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                avatar: Icon(g.icon, size: 16, color: g.color),
                label: Text(g.name),
                selected: _selectedGoalId == g.id,
                onSelected: (_) => setState(() => _selectedGoalId = g.id),
                backgroundColor: colorScheme.surface.withValues(alpha: 0.92),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _LocationRankTile extends StatelessWidget {
  const _LocationRankTile({
    required this.rank,
    required this.name,
    required this.count,
    required this.colorScheme,
  });

  final int rank;
  final String name;
  final int count;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final rankColor = rank <= 3
        ? [
            const Color(0xFFFFD700),
            const Color(0xFFC0C0C0),
            const Color(0xFFCD7F32)
          ][rank - 1]
        : colorScheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: rankColor.withValues(alpha: 0.15),
          child: Text(
            '$rank',
            style: TextStyle(fontWeight: FontWeight.bold, color: rankColor),
          ),
        ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count 次',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentCheckInTile extends StatelessWidget {
  const _RecentCheckInTile({
    required this.record,
    required this.goalName,
    required this.goalColor,
    required this.colorScheme,
  });

  final CheckInRecord record;
  final String goalName;
  final Color goalColor;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: goalColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$goalName · ${record.userLabel}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
                Text(
                  record.locationName ??
                      DateFormat('M月d日 HH:mm').format(record.timestamp),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Text(
            DateFormat('M/d').format(record.timestamp),
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
