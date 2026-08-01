import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/on_this_day_entry.dart';
import '../providers/time_provider.dart';
import '../services/diary_search_service.dart';
import '../services/on_this_day_service.dart';
import '../widgets/date_picker_panel.dart';
import '../widgets/on_this_day_year_card.dart';

/// "那年今日"完整页面：可选择任意日期，查看往年同日的记录
class OnThisDayScreen extends StatefulWidget {
  const OnThisDayScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OnThisDayScreen()),
    );
  }

  @override
  State<OnThisDayScreen> createState() => _OnThisDayScreenState();
}

class _OnThisDayScreenState extends State<OnThisDayScreen> {
  DateTime _selectedDate = DateTime.now();
  bool _isDatePickerVisible = false; // 点击日期栏才展开
  bool _loading = false;
  List<OnThisDayEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<TimeProvider>();
    setState(() => _loading = true);
    try {
      // 等待日记索引就绪（首次进入时提升日记命中率，最多 15 秒超时）
      await _waitForDiaryIndex();
      if (!mounted) return;
      final entries =
          await OnThisDayService.collectEntries(provider, referenceDate: _selectedDate);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _loading = false;
      });
    }
  }

  Future<void> _waitForDiaryIndex() async {
    if (DiarySearchService.isLoaded || !DiarySearchService.isLoading) return;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!DiarySearchService.isLoaded && DiarySearchService.isLoading) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  void _onDateSelected(DateTime date) {
    final normalized = DateTime(date.year, date.month, date.day);
    setState(() {
      _selectedDate = normalized;
      _isDatePickerVisible = false;
    });
    _load();
  }

  String get _dateLabel => '${_selectedDate.month}月${_selectedDate.day}日';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(
          '那年今日',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _buildDateBar(context),
              const Divider(height: 1),
              Expanded(child: _buildBody(context)),
            ],
          ),
          if (_isDatePickerVisible) ...[
            // 半透明遮罩，点击收起
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _isDatePickerVisible = false),
                child: Container(color: Colors.black54),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: DatePickerPanel(
                initialDate: _selectedDate,
                onDateSelected: _onDateSelected,
                onClose: () => setState(() => _isDatePickerVisible = false),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 紧凑日期栏：点击展开日期选择器
  Widget _buildDateBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.surfaceContainerLowest,
      child: InkWell(
        onTap: () => setState(() => _isDatePickerVisible = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.calendar_today_outlined, size: 18),
              const SizedBox(width: 8),
              Text(
                _dateLabel,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_drop_down,
                color: colorScheme.onSurfaceVariant,
              ),
              const Spacer(),
              Text(
                '点击切换日期',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('📅', style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 12),
            Text(
              '$_dateLabel 还没有往年记录',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '这天的记忆还在积累中~',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '$_dateLabel 往年的这一天',
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final entry in _entries) OnThisDayYearCard(entry: entry),
      ],
    );
  }
}
