import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/wake_up_record.dart';
import '../providers/wake_up_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/wake_up_chart.dart';

enum _HistoryPeriod {
  month('最近 30 天'),
  quarter('最近 90 天'),
  all('全部记录'),
  custom('自选日期');

  const _HistoryPeriod(this.label);
  final String label;
}

class WakeUpHistoryScreen extends StatefulWidget {
  const WakeUpHistoryScreen({super.key});

  static Future<void> open(BuildContext context) {
    final provider = context.read<WakeUpProvider>();
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChangeNotifierProvider.value(
        value: provider,
        child: const WakeUpHistoryScreen(),
      ),
    ));
  }

  @override
  State<WakeUpHistoryScreen> createState() => _WakeUpHistoryScreenState();
}

class _WakeUpHistoryScreenState extends State<WakeUpHistoryScreen> {
  _HistoryPeriod _period = _HistoryPeriod.month;
  DateTimeRange? _customRange;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  DateTime _day(DateTime date) => DateTime(date.year, date.month, date.day);

  DateTimeRange _range(DateTime today, List<WakeUpRecord> allRecords) {
    final start = switch (_period) {
      _HistoryPeriod.month => DateTime(today.year, today.month, today.day - 29),
      _HistoryPeriod.quarter =>
        DateTime(today.year, today.month, today.day - 89),
      _HistoryPeriod.all =>
        allRecords.isEmpty ? today : _day(allRecords.last.time),
      _HistoryPeriod.custom => _customRange!.start,
    };
    return DateTimeRange(
      start: start,
      end: _period == _HistoryPeriod.custom ? _customRange!.end : today,
    );
  }

  void _selectPeriod(_HistoryPeriod period) {
    setState(() => _period = period);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Future<void> _pickRange(DateTime today, DateTimeRange range,
      List<WakeUpRecord> allRecords) async {
    var firstDate =
        allRecords.isEmpty ? range.start : _day(allRecords.last.time);
    if (range.start.isBefore(firstDate)) firstDate = range.start;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: today,
      currentDate: today,
      initialDateRange: range,
      helpText: '选择起床记录日期范围',
      saveText: '确定',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          datePickerTheme: DatePickerThemeData(
            backgroundColor: AppSurfaces.of(context).overlay,
            rangePickerBackgroundColor: AppSurfaces.of(context).overlay,
          ),
        ),
        child: child!,
      ),
    );
    if (!mounted || picked == null) return;
    _customRange = picked;
    _selectPeriod(_HistoryPeriod.custom);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WakeUpProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('起床时间统计')),
      body: SafeArea(
        top: false,
        child: provider.loadError != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(provider.loadError!, style: AppText.body),
                    TextButton(
                        onPressed: provider.reload, child: const Text('重试')),
                  ],
                ),
              )
            : !provider.isLoaded
                ? const Center(child: CircularProgressIndicator())
                : provider.kind == null
                    ? const Center(
                        child: Text('请先在“我的”中选择身份', style: AppText.body))
                    : _content(context, provider),
      ),
    );
  }

  Widget _content(BuildContext context, WakeUpProvider provider) {
    final today = _day(provider.now);
    final allRecords = provider.recordsInRange(end: today);
    final range = _range(today, allRecords);
    final startKey = WakeUpRecord.keyForDate(range.start);
    final endKey = WakeUpRecord.keyForDate(range.end);
    final records = allRecords
        .where((record) =>
            record.dateKey.compareTo(startKey) >= 0 &&
            record.dateKey.compareTo(endKey) <= 0)
        .toList(growable: false);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: AppSizes.desktopContentMaxWidth),
        child: CustomScrollView(
          key: const ValueKey('wake-up-history-scroll'),
          controller: _scrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              sliver: SliverList.list(children: [
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final period in _HistoryPeriod.values)
                      ChoiceChip(
                        label: Text(period.label),
                        selected: _period == period,
                        onSelected: (_) => period == _HistoryPeriod.custom
                            ? _pickRange(today, range, allRecords)
                            : _selectPeriod(period),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '${_dateLabel(range.start)} — ${_dateLabel(range.end)}',
                  key: const ValueKey('wake-up-history-range'),
                  style:
                      AppText.caption.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.lg),
                _statistics(context, range, records),
                const SizedBox(height: AppSpacing.xl),
                const Text('每日记录', style: AppText.sectionTitle),
                const SizedBox(height: AppSpacing.sm),
                if (records.isEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Text('所选时段暂无起床记录',
                        textAlign: TextAlign.center,
                        style: AppText.body
                            .copyWith(color: scheme.onSurfaceVariant)),
                  ),
              ]),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
              sliver: SliverList.separated(
                itemCount: records.length,
                separatorBuilder: (context, index) => const Divider(),
                itemBuilder: (context, index) => _recordRow(records[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statistics(
      BuildContext context, DateTimeRange range, List<WakeUpRecord> records) {
    final scheme = Theme.of(context).colorScheme;
    int? average;
    int? earliest;
    int? latest;
    if (records.isNotEmpty) {
      var total = 0;
      for (final record in records) {
        final minute = record.minuteOfDay;
        total += minute;
        if (earliest == null || minute < earliest) earliest = minute;
        if (latest == null || minute > latest) latest = minute;
      }
      average = (total / records.length).round();
    }
    return Container(
      key: const ValueKey('wake-up-history-statistics'),
      padding: AppSpacing.cardComfortable,
      decoration: BoxDecoration(
        color: context.wallpaperFill(AppSurfaces.of(context).card),
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('已记录 ${records.length} 天',
              key: const ValueKey('wake-up-history-count'),
              style: AppText.sectionTitle),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            key: const ValueKey('wake-up-history-metrics'),
            spacing: AppSpacing.xl,
            runSpacing: AppSpacing.md,
            children: [
              _metric(context, '平均起床', average),
              _metric(context, '最早起床', earliest),
              _metric(context, '最晚起床', latest),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('仅统计已记录的日期，未记录的日期不计入平均值。',
              style: AppText.caption.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.lg),
          WakeUpChart.range(
            startDate: range.start,
            endDate: range.end,
            records: records,
            periodLabel:
                _period == _HistoryPeriod.custom ? '所选时段' : _period.label,
          ),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, String label, int? minute) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppText.caption.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.xs),
          Text(minute == null ? '—' : WakeUpRecord.labelForMinute(minute),
              style: AppText.pageTitle),
        ],
      );

  Widget _recordRow(WakeUpRecord record) => Padding(
        key: ValueKey('wake-up-record-${record.dateKey}'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_dateLabel(record.time), style: AppText.body),
                  const SizedBox(height: AppSpacing.xs),
                  Text('星期${'一二三四五六日'[record.time.weekday - 1]}',
                      style: AppText.caption.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Text(record.timeLabel, style: AppText.sectionTitle),
          ],
        ),
      );

  String _dateLabel(DateTime date) => '${date.year}年${date.month}月${date.day}日';
}
