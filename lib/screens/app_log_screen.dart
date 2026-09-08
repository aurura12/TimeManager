import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/app_log_entry.dart';
import '../services/app_log_export_service.dart';
import '../services/app_log_service.dart';

class AppLogScreen extends StatefulWidget {
  const AppLogScreen({super.key, this.service});

  final AppLogService? service;

  @override
  State<AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends State<AppLogScreen> {
  static final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  late final AppLogService _service = widget.service ?? AppLogService.instance;
  AppLogLevel? _selectedLevel;

  @override
  void initState() {
    super.initState();
    unawaited(_service.initialize());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _service,
      builder: (context, child) {
        final allEntries = _service.entries;
        final entries = _selectedLevel == null
            ? allEntries
            : allEntries
                .where((entry) => entry.level == _selectedLevel)
                .toList(growable: false);

        return Scaffold(
          appBar: AppBar(
            title: const Text('运行日志'),
            actions: [
              IconButton(
                tooltip: '导出日志',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: () => _exportLogs(context),
              ),
              IconButton(
                tooltip: '复制全部',
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: () => _copyAllLogs(context),
              ),
              IconButton(
                tooltip: '清空日志',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed:
                    allEntries.isEmpty ? null : () => _clearLogs(context),
              ),
            ],
          ),
          body: Column(
            children: [
              _buildFilterBar(context, allEntries, entries.length),
              Expanded(child: _buildLogList(context, entries)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilterBar(
    BuildContext context,
    List<AppLogEntry> allEntries,
    int visibleCount,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      color: colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterChip(
                  label: '全部',
                  selected: _selectedLevel == null,
                  keyValue: 'log-filter-all',
                  onSelected: (_) => setState(() => _selectedLevel = null),
                ),
                const SizedBox(width: 8),
                for (final level in AppLogLevel.values) ...[
                  _buildFilterChip(
                    label: level.label,
                    selected: _selectedLevel == level,
                    keyValue: 'log-filter-${level.wireName}',
                    onSelected: (_) => setState(() => _selectedLevel = level),
                  ),
                  if (level != AppLogLevel.values.last)
                    const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _selectedLevel == null
                ? '共 ${allEntries.length} 条，按时间倒序显示'
                : '当前显示 $visibleCount 条（共 ${allEntries.length} 条）',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required String keyValue,
    required ValueChanged<bool> onSelected,
  }) {
    return ChoiceChip(
      key: ValueKey<String>(keyValue),
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
    );
  }

  Widget _buildLogList(BuildContext context, List<AppLogEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _service.entries.isEmpty ? '暂无运行日志' : '当前筛选条件下暂无日志',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _buildLogTile(context, entry);
      },
    );
  }

  Widget _buildLogTile(BuildContext context, AppLogEntry entry) {
    final colorScheme = Theme.of(context).colorScheme;
    final levelColor = _levelColor(entry.level, colorScheme);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surfaceContainerLowest,
      child: ListTile(
        dense: true,
        leading: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: levelColor,
            shape: BoxShape.circle,
          ),
        ),
        title: Text(
          entry.message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${_dateFormat.format(entry.localTimestamp)} · ${entry.source} · ${entry.level.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: entry.error == null
            ? null
            : Icon(Icons.error_outline, color: levelColor, size: 20),
        onTap: () => _showLogDetail(context, entry),
      ),
    );
  }

  Color _levelColor(AppLogLevel level, ColorScheme colorScheme) {
    switch (level) {
      case AppLogLevel.info:
        return colorScheme.primary;
      case AppLogLevel.warning:
        return Colors.orange.shade700;
      case AppLogLevel.error:
        return colorScheme.error;
    }
  }

  Future<void> _exportLogs(BuildContext context) async {
    final result = await AppLogExportService.export(_service.entries);
    if (!mounted || result.cancelled) return;
    _showMessage(
      result.success ? '日志已导出' : (result.error ?? '导出日志失败'),
    );
  }

  Future<void> _copyAllLogs(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: AppLogExportService.format(_service.entries)),
    );
    if (!mounted) return;
    _showMessage('日志已复制到剪贴板');
  }

  Future<void> _clearLogs(BuildContext context) async {
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空运行日志？'),
        content: Text('将删除当前保存的 ${_service.entries.length} 条日志。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('log-clear-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (shouldClear != true || !mounted) return;
    await _service.clear();
    if (!mounted) return;
    _showMessage('运行日志已清空');
  }

  Future<void> _showLogDetail(BuildContext context, AppLogEntry entry) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('日志详情'),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          semanticLabel: '日志详情：${entry.level.label}，${entry.source}',
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry.level.label} · ${entry.source}',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _dateFormat.format(entry.localTimestamp),
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SelectableText(entry.message),
                  if (entry.error != null && entry.error!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text(
                      '异常：',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SelectableText(entry.error!),
                  ],
                  if (entry.stackTrace != null &&
                      entry.stackTrace!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text(
                      '堆栈：',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SelectableText(entry.stackTrace!),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('log-detail-copy'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: AppLogExportService.format([entry])),
                );
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (mounted) _showMessage('日志已复制到剪贴板');
              },
              child: const Text('复制此条'),
            ),
            FilledButton(
              key: const ValueKey('log-detail-close'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
