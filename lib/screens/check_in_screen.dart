import 'package:flutter/material.dart';

import '../models/check_in_goal.dart';
import '../models/check_in_record.dart';
import '../models/check_in_view_filter.dart';
import '../models/known_google_users.dart';
import '../services/check_in_sync_service.dart';
import '../services/google_calendar_service.dart';
import '../widgets/check_in_map_preview.dart';
import '../widgets/check_in_photo_sheet.dart';
import 'add_check_in_goal_screen.dart';
import 'check_in_archive_screen.dart';
import 'check_in_detail_screen.dart';
import 'check_in_map_screen.dart';

class CheckInScreen extends StatefulWidget {
  const CheckInScreen({super.key});

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  final _sync = CheckInSyncService();
  CheckInViewFilter _filter = CheckInViewFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {});
    await GoogleCalendarService.restoreSignIn(background: true);
    await _sync.initialize(silent: false);
    if (mounted) setState(() {});
  }

  String? get _currentUserId => _sync.currentUser?.id;

  List<CheckInGoal> get _allGoals => _sync.goalsWithRecords;

  List<CheckInGoal> get _filteredGoals {
    final activeGoals = _allGoals.where((g) => g.isActive).toList();
    switch (_filter) {
      case CheckInViewFilter.all:
        return activeGoals;
      case CheckInViewFilter.guaiGuai:
        return activeGoals
            .where((g) => KnownGoogleUsers.matchesFilter(
                  email: g.ownerEmail,
                  filter: CheckInViewFilter.guaiGuai,
                ))
            .toList();
      case CheckInViewFilter.jingJing:
        return activeGoals
            .where((g) => KnownGoogleUsers.matchesFilter(
                  email: g.ownerEmail,
                  filter: CheckInViewFilter.jingJing,
                ))
            .toList();
    }
  }

  List<CheckInGoal> get _archivedGoals =>
      _allGoals.where((g) => g.isArchived).toList();

  int get _archivedCount => _archivedGoals.length;

  List<CheckInRecord> get _filteredRecords {
    final records = _allGoals.expand((g) => g.records);
    switch (_filter) {
      case CheckInViewFilter.all:
        return records.toList();
      case CheckInViewFilter.guaiGuai:
      case CheckInViewFilter.jingJing:
        return records
            .where((r) => KnownGoogleUsers.matchesFilter(
                  email: r.userEmail,
                  filter: _filter,
                ))
            .toList();
    }
  }

  int get _todayMyCheckedCount {
    final userId = _currentUserId;
    if (userId == null) return 0;
    return _allGoals
        .where((g) => g.isOwnedBy(userId) && g.isCompletedTodayBy(userId))
        .length;
  }

  int get _myGoalCount =>
      _allGoals.where((g) => g.isOwnedBy(_currentUserId ?? '')).length;

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _pull() async {
    final result = await _sync.pullFromGitHub();
    if (!mounted) return;
    setState(() {});
    _showMessage(result.success ? '已同步最新打卡' : (result.error ?? '同步失败'));
  }

  Future<void> _openAddGoal() async {
    if (!_sync.hasIdentity) {
      _showMessage('请先在「我的」中登录一次 Google');
      return;
    }
    final result = await Navigator.push<CheckInGoal>(
      context,
      MaterialPageRoute(builder: (_) => const AddCheckInGoalScreen()),
    );
    if (result == null) return;

    final saveResult = await _sync.saveGoal(result);
    if (!mounted) return;
    setState(() {});
    _showMessage(
      saveResult.success ? '目标已保存并同步' : (saveResult.error ?? '保存失败'),
    );
  }

  Future<void> _openDetail(CheckInGoal goal) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CheckInDetailScreen(goal: goal, syncService: _sync),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _quickCheckIn(CheckInGoal goal) async {
    if (!_sync.hasIdentity) {
      _showMessage('请先登录 Google');
      return;
    }
    final userId = _currentUserId;
    if (userId == null) {
      _showMessage('无法获取用户信息，请重新登录');
      return;
    }
    if (!goal.isOwnedBy(userId)) {
      _showMessage('只能在自己的目标下打卡');
      return;
    }

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CheckInPhotoSheet(goal: goal, syncService: _sync),
    );
    if (ok == true && mounted) {
      setState(() {});
      _showMessage('「${goal.name}」打卡成功');
    }
  }

  Future<void> _backfillCheckIn(CheckInGoal goal) async {
    if (!_sync.hasIdentity) {
      _showMessage('请先登录 Google');
      return;
    }
    final userId = _currentUserId;
    if (userId == null) {
      _showMessage('无法获取用户信息，请重新登录');
      return;
    }
    if (!goal.isOwnedBy(userId)) {
      _showMessage('只能在自己的目标下打卡');
      return;
    }

    // 先选日期，再选时间，然后打卡
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      locale: const Locale('zh'),
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (pickedTime == null || !mounted) return;

    final backfillDt = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CheckInPhotoSheet(
        goal: goal,
        syncService: _sync,
        initialDate: backfillDt,
      ),
    );
    if (ok == true && mounted) {
      setState(() {});
      _showMessage('「${goal.name}」补打卡成功');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('打卡', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        backgroundColor:
            isDark ? colorScheme.surface : const Color(0xFF96B462),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_sync.syncing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: '同步远程数据',
              onPressed: _pull,
            ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加打卡目标',
            onPressed: _openAddGoal,
          ),
        ],
      ),
      body: _sync.loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (!_sync.hasIdentity) _buildSignInBanner(colorScheme),
                if (_sync.hasIdentity && !_sync.isCalendarOnline)
                  _buildOfflineBanner(colorScheme),
                _buildFilterBar(colorScheme),
                Expanded(
                  child: _buildBody(colorScheme, isDark),
                ),
              ],
            ),
    );
  }

  Widget _buildSignInBanner(ColorScheme colorScheme) {
    return MaterialBanner(
      content: const Text('登录一次 Google 后即可识别身份（乖乖/晶晶），并与对方互相看到打卡'),
      leading: Icon(Icons.account_circle, color: colorScheme.primary),
      actions: [
        TextButton(
          onPressed: () => _showMessage('请在底部「我的」→ 设置抽屉中连接 Google'),
          child: const Text('了解'),
        ),
      ],
    );
  }

  Widget _buildOfflineBanner(ColorScheme colorScheme) {
    final label = _sync.currentUser?.label ?? '当前用户';
    return MaterialBanner(
      content: Text('已识别为 $label，日历未连接。打卡正常，同步日历需重新连接'),
      leading: Icon(Icons.wifi_off, color: colorScheme.tertiary),
      actions: [
        TextButton(
          onPressed: _reconnectCalendar,
          child: const Text('重连日历'),
        ),
      ],
    );
  }

  Future<void> _reconnectCalendar() async {
    if (!GoogleCalendarService.isConfigured) {
      _showMessage('未配置 Google 登录');
      return;
    }
    final ok = await GoogleCalendarService.reconnectCalendar();
    if (!mounted) return;
    setState(() {});
    _showMessage(ok ? 'Google 日历已重新连接' : (GoogleCalendarService.lastLoginError ?? '重连失败'));
  }

  Widget _buildFilterBar(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SegmentedButton<CheckInViewFilter>(
        segments: CheckInViewFilter.values
            .map(
              (f) => ButtonSegment(
                value: f,
                label: Text(f.label),
              ),
            )
            .toList(),
        selected: {_filter},
        onSelectionChanged: (s) => setState(() => _filter = s.first),
      ),
    );
  }

  Widget _buildBody(ColorScheme colorScheme, bool isDark) {
    final records = _filteredRecords;
    final userId = _currentUserId;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _buildSummaryCard(colorScheme, isDark, records.length),
        const SizedBox(height: 16),
        _buildMapSection(colorScheme, records),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${_filter.label}的打卡目标',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            if (_filter != CheckInViewFilter.all && userId != null)
              Text(
                '今日 $_todayMyCheckedCount/$_myGoalCount',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_filteredGoals.isEmpty)
          _buildGoalsEmptyHint(colorScheme)
        else
          ..._filteredGoals.map(
            (goal) => _buildGoalCard(goal, colorScheme, isDark, userId),
          ),
        if (_archivedCount > 0) ...[
          const SizedBox(height: 16),
          _buildArchiveEntry(colorScheme),
        ],
      ],
    );
  }

  Widget _buildGoalsEmptyHint(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.check_circle_outline,
                size: 48,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45)),
            const SizedBox(height: 12),
            Text(
              '${_filter.label}还没有打卡目标',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            if (_filter == CheckInViewFilter.all) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _openAddGoal,
                icon: const Icon(Icons.add),
                label: const Text('创建打卡目标'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildArchiveEntry(ColorScheme colorScheme) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CheckInArchiveScreen(syncService: _sync),
          ),
        );
        if (mounted) setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.archive, size: 20, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '已归档的目标',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$_archivedCount',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right,
                size: 20, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(
      ColorScheme colorScheme, bool isDark, int recordCount) {
    final userId = _currentUserId ?? '';
    final maxStreak = _allGoals.isEmpty
        ? 0
        : _allGoals
            .where((g) => userId.isEmpty || g.isOwnedBy(userId))
            .map((g) => g.streakDaysFor(userId))
            .fold(0, (a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [colorScheme.primaryContainer, colorScheme.surfaceContainerHigh]
              : [const Color(0xFF96B462), const Color(0xFF7FA34E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SummaryItem(
              label: '打卡次数',
              value: '$recordCount',
              unit: '次',
              textColor: isDark ? colorScheme.onPrimaryContainer : Colors.white,
            ),
          ),
          _divider(isDark, colorScheme),
          Expanded(
            child: _SummaryItem(
              label: '最长连续',
              value: '$maxStreak',
              unit: '天',
              textColor: isDark ? colorScheme.onPrimaryContainer : Colors.white,
            ),
          ),
          _divider(isDark, colorScheme),
          Expanded(
            child: _SummaryItem(
              label: '目标数',
              value: '${_filteredGoals.length}',
              unit: '个',
              textColor: isDark ? colorScheme.onPrimaryContainer : Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(bool isDark, ColorScheme colorScheme) {
    return Container(
      width: 1,
      height: 40,
      color: (isDark ? colorScheme.onPrimaryContainer : Colors.white)
          .withValues(alpha: 0.3),
    );
  }

  Widget _buildMapSection(ColorScheme colorScheme, List<CheckInRecord> records) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '打卡地图',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            TextButton(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CheckInMapScreen(
                      goals: _allGoals,
                      syncService: _sync,
                      initialFilter: _filter,
                    ),
                  ),
                );
                if (mounted) setState(() {});
              },
              child: const Text('查看全部'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        CheckInMapPreview(
          records: records,
          height: 220,
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CheckInMapScreen(
                  goals: _allGoals,
                  syncService: _sync,
                  initialFilter: _filter,
                ),
              ),
            );
            if (mounted) setState(() {});
          },
        ),
      ],
    );
  }

  Widget _buildGoalCard(
    CheckInGoal goal,
    ColorScheme colorScheme,
    bool isDark,
    String? userId,
  ) {
    final cardColor = isDark
        ? Color.lerp(goal.color, colorScheme.surfaceContainerHigh, 0.45)!
        : goal.color;
    final onCardColor =
        ThemeData.estimateBrightnessForColor(cardColor) == Brightness.dark
            ? Colors.white
            : Colors.black87;
    final mutedColor = onCardColor.withValues(alpha: 0.75);
    final isMine = userId != null && goal.isOwnedBy(userId);
    final checked = userId != null && goal.isCompletedTodayBy(userId);
    final progressUserId = _filter == CheckInViewFilter.all
        ? null
        : _filter == CheckInViewFilter.guaiGuai
            ? _userIdForFilter(CheckInViewFilter.guaiGuai)
            : _userIdForFilter(CheckInViewFilter.jingJing);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openDetail(goal),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: onCardColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(goal.icon, color: onCardColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(goal.name,
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: onCardColor)),
                          Text(
                            isMine ? goal.description : '${goal.ownerLabel} 的目标',
                            style: TextStyle(fontSize: 12, color: mutedColor),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (checked)
                      _badge('已打卡', onCardColor),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: goal.progressFor(progressUserId),
                          minHeight: 6,
                          backgroundColor: onCardColor.withValues(alpha: 0.2),
                          valueColor:
                              AlwaysStoppedAnimation<Color>(onCardColor),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${goal.currentPeriodCountFor(progressUserId)}/${goal.targetCount}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: onCardColor),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.local_fire_department,
                        size: 14, color: mutedColor),
                    const SizedBox(width: 4),
                    Text(
                      '连续 ${goal.streakDaysFor(progressUserId ?? goal.ownerId)} 天',
                      style: TextStyle(fontSize: 12, color: mutedColor),
                    ),
                    const Spacer(),
                    if (isMine && !checked) ...[
                      TextButton(
                        onPressed: () => _backfillCheckIn(goal),
                        style: TextButton.styleFrom(
                          foregroundColor: onCardColor.withValues(alpha: 0.7),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20)),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: const Text('补打卡',
                            style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: () => _quickCheckIn(goal),
                        style: TextButton.styleFrom(
                          foregroundColor: onCardColor,
                          backgroundColor: onCardColor.withValues(alpha: 0.15),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20)),
                        ),
                        icon: const Icon(Icons.camera_alt, size: 16),
                        label: const Text('打卡', style: TextStyle(fontSize: 13)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _userIdForFilter(CheckInViewFilter filter) {
    final email = filter == CheckInViewFilter.guaiGuai
        ? KnownGoogleUsers.guaiGuaiEmail
        : KnownGoogleUsers.jingJingEmail;
    for (final g in _allGoals) {
      if (KnownGoogleUsers.normalizeEmail(g.ownerEmail) ==
          KnownGoogleUsers.normalizeEmail(email)) {
        return g.ownerId;
      }
    }
    for (final r in _allGoals.expand((g) => g.records)) {
      if (KnownGoogleUsers.normalizeEmail(r.userEmail) ==
          KnownGoogleUsers.normalizeEmail(email)) {
        return r.userId;
      }
    }
    return null;
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.label,
    required this.value,
    required this.unit,
    required this.textColor,
  });

  final String label;
  final String value;
  final String unit;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 12, color: textColor.withValues(alpha: 0.8))),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: textColor)),
            const SizedBox(width: 2),
            Text(unit,
                style: TextStyle(
                    fontSize: 12, color: textColor.withValues(alpha: 0.8))),
          ],
        ),
      ],
    );
  }
}
