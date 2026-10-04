import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/diary_kind.dart';
import '../models/sync_center_state.dart';
import '../models/wake_up_record.dart';
import '../providers/wake_up_provider.dart';
import '../screens/wake_up_history_screen.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'main_tab_activity.dart';
import 'time_wheel_sheet.dart';
import 'wake_up_chart.dart';

class WakeUpCard extends StatefulWidget {
  const WakeUpCard({super.key});

  @override
  State<WakeUpCard> createState() => _WakeUpCardState();
}

class _WakeUpCardState extends State<WakeUpCard> with WidgetsBindingObserver {
  Timer? _timer;
  bool _showHistory = false;
  bool _isActive = false;
  late WakeUpProvider _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider = context.read<WakeUpProvider>();
    _isActive = MainTabActivity.isActiveOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _refreshTimer();
  }

  void _refreshTimer() {
    _timer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_isActive &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      // 用真实时间重新计算，切后台或关闭 App 都不会丢失已起床时长。
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _refreshTimer();
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WakeUpProvider>();
    final scheme = Theme.of(context).colorScheme;
    final now = provider.now;
    final today = provider.recordFor(now);
    return Container(
      key: const ValueKey('wake-up-card'),
      padding: AppSpacing.cardComfortable,
      decoration: BoxDecoration(
        color: context.wallpaperFill(AppSurfaces.of(context).card),
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wb_sunny_outlined, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(
                child: Text('起床时间', style: AppText.sectionTitle),
              ),
              Text('今天',
                  style:
                      AppText.caption.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (provider.loadError != null) ...[
            Text(provider.loadError!, style: AppText.body),
            TextButton(onPressed: provider.reload, child: const Text('重试')),
          ] else if (!provider.isLoaded) ...[
            const Text('正在读取起床记录…', style: AppText.body),
          ] else if (provider.kind == null) ...[
            const Text('请先在“我的”中选择身份，再记录起床时间', style: AppText.body),
          ] else ...[
            LayoutBuilder(builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context)
                      .scale(AppText.caption.fontSize!) /
                  AppText.caption.fontSize!;
              final details = _todayDetails(context, provider, now, today);
              final chart = WakeUpChart(
                today: now,
                records: provider.recentRecords(now),
              );
              if (constraints.maxWidth >=
                  AppSizes.desktopTargetRowBreakpoint * textScale) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: details),
                    const SizedBox(width: AppSpacing.xl),
                    Expanded(flex: 3, child: chart),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  details,
                  const SizedBox(height: AppSpacing.lg),
                  chart,
                ],
              );
            }),
            const SizedBox(height: AppSpacing.sm),
            Divider(color: scheme.outlineVariant),
            _historySummary(context, provider, now),
            if (_showHistory) ...[
              const SizedBox(height: AppSpacing.sm),
              for (var offset = 0; offset < 7; offset++)
                _historyRow(
                  context,
                  DateTime(now.year, now.month, now.day - offset),
                  offset == 0,
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _todayDetails(BuildContext context, WakeUpProvider provider,
      DateTime now, WakeUpRecord? today) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('wake-up-today'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (today == null) ...[
          const Text('今天还未记录起床时间', style: AppText.body),
          const SizedBox(height: AppSpacing.xs),
          Text('起床后点一下，也可以补填实际时间。',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant)),
        ] else
          Wrap(
            spacing: AppSpacing.xl,
            runSpacing: AppSpacing.md,
            children: [
              _metric(context, '今天起床', today.timeLabel),
              _metric(context, '已起床', _elapsedLabel(today.elapsedAt(now))),
            ],
          ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (today == null) ...[
              FilledButton.icon(
                key: const ValueKey('wake-up-now'),
                onPressed: provider.canRecord
                    ? () => _saveTime(provider, provider.now, provider.kind!,
                        replaceExisting: false)
                    : null,
                icon: const Icon(Icons.check),
                label: Text(provider.isSaving ? '正在保存…' : '我起床了'),
              ),
              TextButton(
                key: const ValueKey('wake-up-edit'),
                onPressed: provider.canRecord ? () => _pickTime(now) : null,
                child: const Text('补填时间'),
              ),
            ] else ...[
              OutlinedButton.icon(
                key: const ValueKey('wake-up-edit'),
                onPressed: provider.canRecord ? () => _pickTime(now) : null,
                icon: const Icon(Icons.edit_outlined),
                label: Text(provider.isSaving ? '正在保存…' : '修改时间'),
              ),
              TextButton(
                onPressed: provider.canRecord ? () => _remove(today) : null,
                child: const Text('删除记录'),
              ),
            ],
          ],
        ),
        if (provider.syncEnabled) ...[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_syncLabel(provider.syncStatus),
                  style:
                      AppText.caption.copyWith(color: scheme.onSurfaceVariant)),
              if (provider.syncStatus == SyncModuleStatus.failed ||
                  provider.syncStatus == SyncModuleStatus.offline ||
                  provider.syncStatus == SyncModuleStatus.conflict)
                TextButton(
                  key: const ValueKey('wake-up-sync-retry'),
                  onPressed: provider.isSaving
                      ? null
                      : () => provider.synchronize(source: '目标页重试'),
                  child: const Text('重试同步'),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: AppText.caption.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.xs),
        Text(value, style: AppText.pageTitle),
      ],
    );
  }

  Widget _historySummary(
      BuildContext context, WakeUpProvider provider, DateTime now) {
    final average = provider.averageMinute(now);
    final count = provider.recentRecords(now).length;
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          key: const ValueKey('wake-up-history-toggle'),
          onPressed: () => setState(() => _showHistory = !_showHistory),
          icon: Icon(_showHistory ? Icons.expand_less : Icons.expand_more),
          label: const Text('最近 7 天'),
        ),
        Text(
          average == null
              ? '尚无起床记录'
              : '平均 ${WakeUpRecord.labelForMinute(average)} · 已记录 $count 天',
          style: AppText.caption
              .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        TextButton.icon(
          key: const ValueKey('wake-up-history-more'),
          onPressed: () => WakeUpHistoryScreen.open(context),
          icon: const Icon(Icons.chevron_right),
          iconAlignment: IconAlignment.end,
          label: const Text('查看更多'),
        ),
      ],
    );
  }

  Widget _historyRow(BuildContext context, DateTime date, bool isToday) {
    final record = _provider.recordFor(date);
    final dateKey = WakeUpRecord.keyForDate(date);
    return Row(
      children: [
        Expanded(
          child: Text('${date.month}月${date.day}日${isToday ? '（今天）' : ''}',
              style: AppText.body),
        ),
        TextButton(
          key: ValueKey('wake-up-history-$dateKey'),
          onPressed: _provider.canRecord ? () => _pickTime(date) : null,
          child: Text(record?.timeLabel ?? '补填'),
        ),
        if (record != null)
          IconButton(
            tooltip: '删除${date.month}月${date.day}日起床记录',
            onPressed: _provider.canRecord ? () => _remove(record) : null,
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    );
  }

  Future<void> _pickTime(DateTime date) async {
    final provider = _provider;
    final kind = provider.kind;
    if (kind == null) return;
    final record = provider.recordFor(date);
    final initial = record?.time ??
        (WakeUpRecord.keyForDate(date) == WakeUpRecord.keyForDate(provider.now)
            ? provider.now
            : DateTime(date.year, date.month, date.day, 7));
    final picked = await showTimeWheelSheet(context,
        initialTime: TimeOfDay.fromDateTime(initial),
        title: '${date.month}月${date.day}日起床时间');
    if (!mounted || picked == null) return;
    await _saveTime(
        provider,
        DateTime(date.year, date.month, date.day, picked.hour, picked.minute),
        kind);
  }

  Future<void> _saveTime(WakeUpProvider provider, DateTime time, DiaryKind kind,
      {bool replaceExisting = true}) async {
    try {
      await provider.record(time,
          expectedKind: kind, replaceExisting: replaceExisting);
      if (mounted) _message('已记录起床时间 ${WakeUpRecord(time).timeLabel}');
    } catch (error) {
      if (mounted) _message(_errorMessage(error));
    }
  }

  Future<void> _remove(WakeUpRecord record) async {
    final provider = _provider;
    final kind = provider.kind;
    if (kind == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除起床记录'),
        content: Text('删除 ${record.time.month}月${record.time.day}日 '
            '${record.timeLabel} 的起床记录？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await provider.remove(record.time, expectedKind: kind);
      if (mounted) _message('已删除起床记录');
    } catch (error) {
      if (mounted) _message(_errorMessage(error));
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String _errorMessage(Object error) => switch (error) {
        ArgumentError() => error.message.toString(),
        StateError() => error.message,
        _ => '起床记录保存失败，请重试',
      };

  String _elapsedLabel(Duration elapsed) {
    if (elapsed.inMinutes == 0) return '不足 1 分钟';
    if (elapsed.inHours == 0) return '${elapsed.inMinutes} 分钟';
    return '${elapsed.inHours} 小时 ${elapsed.inMinutes % 60} 分钟';
  }

  String _syncLabel(SyncModuleStatus status) => switch (status) {
        SyncModuleStatus.success => '已同步到 Gitee',
        SyncModuleStatus.syncing => '正在同步起床记录…',
        SyncModuleStatus.pending => '等待同步到 Gitee',
        SyncModuleStatus.offline => '离线待同步，本机记录已保存',
        SyncModuleStatus.failed || SyncModuleStatus.conflict => '起床记录同步失败，可重试',
        _ => status.label,
      };
}
