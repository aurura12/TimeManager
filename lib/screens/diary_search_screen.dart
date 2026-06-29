import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/diary_search_result.dart';
import '../services/diary_search_service.dart';

class DiarySearchScreen extends StatefulWidget {
  const DiarySearchScreen({super.key});

  @override
  State<DiarySearchScreen> createState() => _DiarySearchScreenState();
}

class _DiarySearchScreenState extends State<DiarySearchScreen> {
  final _controller = TextEditingController();
  List<DiarySearchResult> _results = [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() {
      _results = DiarySearchService.search(_controller.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final query = _controller.text;

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
            hintText: '搜索日记内容…',
            hintStyle: TextStyle(
              color: (isDark ? colorScheme.onPrimary : Colors.white)
                  .withValues(alpha: 0.7),
            ),
            border: InputBorder.none,
            suffixIcon: query.isNotEmpty
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
      body: query.trim().isEmpty
          ? _buildHint(isDark, colorScheme)
          : _results.isEmpty
              ? _buildEmpty(isDark, colorScheme, query)
              : _buildResults(isDark, colorScheme),
    );
  }

  Widget _buildHint(bool isDark, ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search,
            size: 48,
            color: isDark ? colorScheme.outlineVariant : Colors.grey[300],
          ),
          const SizedBox(height: 12),
          Text(
            '输入关键词搜索日记',
            style: TextStyle(
              color: isDark ? colorScheme.onSurfaceVariant : Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(bool isDark, ColorScheme colorScheme, String query) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: isDark ? colorScheme.outlineVariant : Colors.grey[300],
          ),
          const SizedBox(height: 12),
          Text(
            '未找到「$query」相关日记',
            style: TextStyle(
              color: isDark ? colorScheme.onSurfaceVariant : Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(bool isDark, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '共 ${_results.length} 条结果',
            style: TextStyle(
              color: isDark ? colorScheme.onSurfaceVariant : Colors.grey[600],
              fontSize: 13,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final result = _results[index];
              final isG = result.kind == 'g';

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? colorScheme.surfaceContainerHighest
                      : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: (isDark ? Colors.white : Colors.black)
                          .withValues(alpha: isDark ? 0.02 : 0.03),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: InkWell(
                  onTap: () => Navigator.pop(context, result),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: isG
                                    ? const Color(0xFF4DA8EE)
                                    : const Color(0xFFF16B77),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '${result.kindLabel}  ${DateFormat('yyyy-MM-dd').format(result.date)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: isDark
                                    ? colorScheme.onSurface
                                : Colors.black87,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: isDark
                              ? colorScheme.onSurfaceVariant
                              : Colors.grey[400],
                        ),
                      ],
                        ),
                        if (result.snippet.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            result.snippet,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? colorScheme.onSurfaceVariant
                                  : Colors.grey[600],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
