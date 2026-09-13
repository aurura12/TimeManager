import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/diary_search_result.dart';
import '../services/diary_search_service.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
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
    final colorScheme = Theme.of(context).colorScheme;
    final query = _controller.text;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 16,
          ),
          decoration: InputDecoration(
            hintText: '搜索日记内容…',
            hintStyle: TextStyle(
              color: colorScheme.onSurfaceVariant,
            ),
            border: InputBorder.none,
            suffixIcon: query.isNotEmpty
                ? IconButton(
                    icon: Icon(
                      Icons.clear,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () => _controller.clear(),
                  )
                : null,
          ),
        ),
      ),
      body: query.trim().isEmpty
          ? _buildHint(colorScheme)
          : _results.isEmpty
              ? _buildEmpty(colorScheme, query)
              : _buildResults(colorScheme),
    );
  }

  Widget _buildHint(ColorScheme colorScheme) {
    // 索引正在构建中，显示进度
    if (DiarySearchService.isLoading) {
      return Center(
        child: ValueListenableBuilder<double>(
          valueListenable: DiarySearchService.progress,
          builder: (context, value, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.hourglass_top,
                  size: 48,
                  color: colorScheme.outlineVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  '正在构建日记索引...',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 200,
                  child: LinearProgressIndicator(
                    value: value > 0 ? value : null,
                    minHeight: 4,
                    borderRadius: AppRadius.gridAll,
                  ),
                ),
                if (value > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${(value * 100).toInt()}%',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search,
            size: 48,
            color: colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            DiarySearchService.hasData ? '输入关键词搜索日记' : '暂无索引数据，请同步日记后再试',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme colorScheme, String query) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '未找到「$query」相关日记',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '共 ${_results.length} 条结果',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
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
                  color: AppSurfaces.of(context).card,
                  borderRadius: AppRadius.cardAll,
                  // 卡片：弱边框、少阴影
                  border: Border.all(color: AppSurfaces.of(context).border),
                ),
                child: InkWell(
                  onTap: () => Navigator.pop(context, result),
                  borderRadius: AppRadius.cardAll,
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
                                    ? AppSemanticColors.identityGuaiGuai
                                    : AppSemanticColors.identityJingJing,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '${result.kindLabel}  ${DateFormat('yyyy年M月d日').format(result.date)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: colorScheme.onSurfaceVariant,
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
                              color: colorScheme.onSurfaceVariant,
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
