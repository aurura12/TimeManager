import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/search_result.dart';
import '../providers/time_provider.dart';
import '../theme/app_theme.dart';
import 'dart:async';

enum _SearchDateRange { all, week, month, year }

class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  _SearchDateRange _dateRange = _SearchDateRange.all;
  List<SearchRecordGroup> _results = [];
  String _query = '';
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounceTimer?.cancel();
    final query = _controller.text;
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _query = query;
        _runSearch();
      });
    });
  }

  DateTime? _rangeStart() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_dateRange) {
      case _SearchDateRange.all:
        return null;
      case _SearchDateRange.week:
        return today.subtract(const Duration(days: 6));
      case _SearchDateRange.month:
        return today.subtract(const Duration(days: 29));
      case _SearchDateRange.year:
        return DateTime(now.year - 1, now.month, now.day);
    }
  }

  void _runSearch() {
    if (_query.trim().isEmpty) {
      _results = [];
      return;
    }
    final provider = context.read<TimeProvider>();
    _results = provider.searchRecords(
      _query,
      startDate: _rangeStart(),
    );
  }

  void _selectLabel(String label) {
    _controller.text = label;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: label.length),
    );
  }

  void _openDate(DateTime date) {
    context.read<TimeProvider>().goToDate(date);
    Navigator.pop(context);
  }

  String _formatDuration(int minutes) {
    if (minutes < 60) return '${minutes}分钟';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (m == 0) return '${h}小时';
    return '${h}小时${m}分钟';
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    if (d == today) return '今天 ${date.month}月${date.day}日';
    if (d == today.subtract(const Duration(days: 1))) {
      return '昨天 ${date.month}月${date.day}日';
    }
    return '${date.year}年${date.month}月${date.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimeProvider>();
    final suggestions = provider.getSearchableLabels();
    final totalMinutes =
        _results.fold(0, (sum, g) => sum + g.totalMinutes);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF8F9FA),
      appBar: AppBar(
        backgroundColor: isDark ? colorScheme.primary : const Color(0xFF9CB86A),
        foregroundColor: isDark ? colorScheme.onPrimary : Colors.white,
        title: TextField(
          controller: _controller,
          autofocus: true,
          style: TextStyle(
            color: isDark ? colorScheme.onPrimary : Colors.white,
            fontSize: 16,
          ),
          decoration: InputDecoration(
            hintText: '搜索事件或分类…',
            hintStyle: TextStyle(
              color: (isDark ? colorScheme.onPrimary : Colors.white)
                  .withValues(alpha: 0.7),
            ),
            border: InputBorder.none,
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    icon: Icon(
                      Icons.clear,
                      color: isDark
                          ? colorScheme.onPrimary.withValues(alpha: 0.7)
                          : Colors.white70,
                    ),
                    onPressed: () => _controller.clear(),
                  )
                : null,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                _rangeChip('全部', _SearchDateRange.all, isDark, colorScheme),
                _rangeChip('近7天', _SearchDateRange.week, isDark, colorScheme),
                _rangeChip('近30天', _SearchDateRange.month, isDark, colorScheme),
                _rangeChip('近一年', _SearchDateRange.year, isDark, colorScheme),
              ],
            ),
          ),
          if (_query.trim().isNotEmpty && _results.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '共 ${_results.length} 天 · ${_formatDuration(totalMinutes)}',
                style: TextStyle(
                  color: isDark
                      ? colorScheme.onSurfaceVariant
                      : Colors.grey[600],
                  fontSize: 13,
                ),
              ),
            ),
          Expanded(
            child: _query.trim().isEmpty
                ? _buildSuggestions(suggestions, isDark, colorScheme)
                : _results.isEmpty
                    ? _buildEmpty(isDark, colorScheme)
                    : _buildResults(isDark, colorScheme),
          ),
        ],
      ),
    );
  }

  Widget _rangeChip(
    String label,
    _SearchDateRange range,
    bool isDark,
    ColorScheme colorScheme,
  ) {
    final selected = _dateRange == range;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() {
            _dateRange = range;
            _runSearch();
          });
        },
        selectedColor: isDark
            ? AppTheme.seedColor.withValues(alpha: 0.3)
            : const Color(0xFF9CB86A).withValues(alpha: 0.25),
        checkmarkColor: isDark
            ? const Color(0xFFB5D390)
            : const Color(0xFF9CB86A),
        labelStyle: TextStyle(
          color: selected
              ? const Color(0xFF5A7A32)
              : (isDark ? colorScheme.onSurface : Colors.black87),
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _buildSuggestions(List<String> labels, bool isDark, ColorScheme colorScheme) {
    if (labels.isEmpty) {
      return Center(
        child: Text('暂无记录，先去首页记录时间吧',
            style: TextStyle(
              color: isDark
                  ? colorScheme.onSurfaceVariant
                  : Colors.grey[500],
            )),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('快速搜索',
            style: TextStyle(
                color: isDark
                    ? colorScheme.onSurfaceVariant
                    : Colors.grey[600],
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: labels.map((label) {
            return ActionChip(
              label: Text(
                label,
                style: TextStyle(
                  color: isDark ? colorScheme.onSurface : Colors.black87,
                ),
              ),
              backgroundColor:
                  isDark ? colorScheme.surfaceContainerHigh : Colors.white,
              side: BorderSide(
                color: isDark
                    ? colorScheme.outlineVariant
                    : Colors.grey[300]!,
              ),
              onPressed: () => _selectLabel(label),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildEmpty(bool isDark, ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: isDark
                ? colorScheme.outlineVariant
                : Colors.grey[300],
          ),
          const SizedBox(height: 12),
          Text('未找到「$_query」的相关记录',
              style: TextStyle(
                color: isDark
                    ? colorScheme.onSurfaceVariant
                    : Colors.grey[500],
              )),
        ],
      ),
    );
  }

  Widget _buildResults(bool isDark, ColorScheme colorScheme) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final group = _results[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: isDark
                ? colorScheme.surfaceContainerHighest
                : Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: isDark ? 0.02 : 0.03),
                blurRadius: 8,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => _openDate(group.date),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _formatDateHeader(group.date),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: isDark
                                ? const Color(0xFFB5D390)
                                : const Color(0xFF9CB86A),
                          ),
                        ),
                      ),
                      Text(
                        _formatDuration(group.totalMinutes),
                        style: TextStyle(
                          color: isDark
                              ? colorScheme.onSurfaceVariant
                              : Colors.grey[500],
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: isDark
                            ? colorScheme.onSurfaceVariant
                            : Colors.grey[400],
                      ),
                    ],
                  ),
                ),
              ),
              ...group.entries.map((entry) {
                return Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: entry.color ?? const Color(0xFF9CB86A),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          entry.label,
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark
                                ? colorScheme.onSurface
                                : Colors.black87,
                          ),
                        ),
                      ),
                      Text(
                        entry.timeRange,
                        style: TextStyle(
                          color: isDark
                              ? colorScheme.onSurfaceVariant
                              : Colors.grey[600],
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatDuration(entry.durationMinutes),
                        style: TextStyle(
                          color: isDark
                              ? colorScheme.onSurfaceVariant
                              : Colors.grey[400],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }
}
