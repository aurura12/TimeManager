import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/diary_kind.dart';
import '../services/diary_github_service.dart';
import '../services/diary_local_store.dart';

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  final TextEditingController _bodyController = TextEditingController();

  DiaryKind _kind = DiaryKind.g;
  DateTime _selectedDate = DateTime.now();
  DateTime? _startedAt;
  String? _token;
  bool _loading = true;
  bool _processing = false;
  bool _suppressBodyListener = false;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    _bodyController.addListener(_onBodyChanged);
    _loadInitial();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _bodyController.removeListener(_onBodyChanged);
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    final token = await DiaryLocalStore.loadToken();
    final kind = await DiaryLocalStore.loadPreferredKind();
    _token = token;
    _kind = kind;
    await _loadDraftForCurrentContext();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  String _selectedDateText() {
    return DateFormat('yyyy-MM-dd').format(_selectedDate);
  }

  String _frontMatterTitle(DateTime startedAt) {
    final dayText = DateFormat('yyyy年M月d日').format(startedAt);
    return '${_kind.prefix}$dayText';
  }

  String _frontMatterDate(DateTime startedAt) {
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(startedAt);
  }

  String _buildMarkdownContent() {
    final started = _startedAt ?? DateTime.now();
    final body = _bodyController.text;
    return '---\n'
        'title: ${_frontMatterTitle(started)}\n'
        'date: ${_frontMatterDate(started)}\n'
        'tags:\n'
        '---\n'
        '$body';
  }

  String _buildFileName() {
    final dayText = DateFormat('yyyy年M月d日').format(_selectedDate);
    return '${_kind.prefix}$dayText.md';
  }

  Future<void> _loadDraftForCurrentContext() async {
    final body = await DiaryLocalStore.loadDraftBody(_kind, _selectedDate);
    final startedAt =
        await DiaryLocalStore.loadDraftStartedAt(_kind, _selectedDate);
    _suppressBodyListener = true;
    _bodyController.text = body ?? '';
    _suppressBodyListener = false;
    _startedAt = startedAt;
  }

  Future<void> _saveDraftNow() async {
    await DiaryLocalStore.saveDraftBody(
      _kind,
      _selectedDate,
      _bodyController.text,
    );
    if (_startedAt != null) {
      await DiaryLocalStore.saveDraftStartedAt(_kind, _selectedDate, _startedAt!);
    }
  }

  void _onBodyChanged() {
    if (_suppressBodyListener) return;
    _startedAt ??= DateTime.now();
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 350), () {
      _saveDraftNow();
      if (mounted) setState(() {});
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    await _saveDraftNow();
    _selectedDate = DateTime(picked.year, picked.month, picked.day);
    await _loadDraftForCurrentContext();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _changeKind(DiaryKind kind) async {
    if (_kind == kind) return;
    await _saveDraftNow();
    _kind = kind;
    await DiaryLocalStore.savePreferredKind(kind);
    await _loadDraftForCurrentContext();
    if (!mounted) return;
    setState(() {});
  }

  DateTime? _parseStartedAtFromMarkdown(String markdown) {
    final match = RegExp(r'^---\n([\s\S]*?)\n---\n?', multiLine: false)
        .firstMatch(markdown);
    if (match == null) return null;
    final frontMatter = match.group(1) ?? '';
    final dateLine = RegExp(r'^date:\s*(.+)$', multiLine: true)
        .firstMatch(frontMatter)
        ?.group(1)
        ?.trim();
    if (dateLine == null || dateLine.isEmpty) return null;
    try {
      return DateFormat('yyyy-MM-dd HH:mm:ss').parseStrict(dateLine);
    } catch (_) {
      return DateTime.tryParse(dateLine);
    }
  }

  String _extractBodyFromMarkdown(String markdown) {
    final match = RegExp(r'^---\n([\s\S]*?)\n---\n?', multiLine: false)
        .firstMatch(markdown);
    if (match == null) return markdown;
    return markdown.substring(match.end);
  }

  String _extractTitleFromMarkdown(String markdown) {
    final match = RegExp(r'^---\n([\s\S]*?)\n---\n?', multiLine: false)
        .firstMatch(markdown);
    if (match == null) return '';
    final frontMatter = match.group(1) ?? '';
    return RegExp(r'^title:\s*(.+)$', multiLine: true)
            .firstMatch(frontMatter)
            ?.group(1)
            ?.trim() ??
        '';
  }

  Future<void> _loadRemoteFileToEditor(String path) async {
    final result = await DiaryGitHubService.pullDiary(token: _token!, path: path);
    if (!mounted) return;
    if (!result.success) {
      _showMessage(result.error ?? '加载远程文件失败');
      return;
    }

    final raw = result.content!;
    final body = _extractBodyFromMarkdown(raw);
    final startedAt = _parseStartedAtFromMarkdown(raw);

    final fileName = path.split('/').last;
    final isG = fileName.startsWith('G');
    final isJ = fileName.startsWith('J');
    if (isG || isJ) {
      final newKind = isG ? DiaryKind.g : DiaryKind.j;
      if (_kind != newKind) {
        _kind = newKind;
        await DiaryLocalStore.savePreferredKind(newKind);
      }
    }

    _suppressBodyListener = true;
    _bodyController.text = body;
    _suppressBodyListener = false;
    _startedAt = startedAt ?? DateTime.now();
    await _saveDraftNow();
    setState(() {});
    _showMessage('已载入：$path');
  }

  Future<void> _browseRemoteDiaries() async {
    final ok = await _ensureToken();
    if (!ok) return;

    setState(() => _processing = true);
    final listResult = await DiaryGitHubService.listDiaryPaths(token: _token!);
    if (!mounted) return;
    setState(() => _processing = false);

    if (!listResult.success) {
      _showMessage(listResult.error ?? '读取远程列表失败');
      return;
    }
    if (listResult.paths.isEmpty) {
      _showMessage('远程仓库未找到 G/J 日记文件');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return Column(
              children: [
                const SizedBox(height: 12),
                const Text(
                  '远程日记',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.separated(
                    controller: controller,
                    itemCount: listResult.paths.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final path = listResult.paths[index];
                      final name = path.split('/').last;
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(path,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () async {
                          Navigator.pop(ctx);
                          if (!mounted) return;
                          setState(() => _processing = true);
                          final pull = await DiaryGitHubService.pullDiary(
                            token: _token!,
                            path: path,
                          );
                          if (!mounted) return;
                          setState(() => _processing = false);
                          if (!pull.success) {
                            _showMessage(pull.error ?? '读取远程文件失败');
                            return;
                          }
                          await _showRemoteDiaryViewer(path, pull.content!);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showRemoteDiaryViewer(String path, String markdown) async {
    final title = _extractTitleFromMarkdown(markdown);
    final body = _extractBodyFromMarkdown(markdown);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            title.isEmpty ? path.split('/').last : title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(body.isEmpty ? '(空内容)' : body),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _loadRemoteFileToEditor(path);
              },
              child: const Text('载入到编辑器'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _ensureToken() async {
    if ((_token ?? '').trim().isNotEmpty) return true;

    final controller = TextEditingController(text: _token ?? '');
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('设置 GitHub Token'),
          content: TextField(
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '粘贴 Personal Access Token',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (token == null || token.isEmpty) return false;
    _token = token;
    await DiaryLocalStore.saveToken(token);
    return true;
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _pullDiary() async {
    final ok = await _ensureToken();
    if (!ok) return;

    setState(() => _processing = true);
    final path = _buildFileName();
    final result = await DiaryGitHubService.pullDiary(
      token: _token!,
      path: path,
    );
    if (!mounted) return;
    if (result.success) {
      final raw = result.content!;
      final body = _extractBodyFromMarkdown(raw);
      final startedAt = _parseStartedAtFromMarkdown(raw);
      _suppressBodyListener = true;
      _bodyController.text = body;
      _suppressBodyListener = false;
      _startedAt = startedAt ?? DateTime.now();
      await _saveDraftNow();
      _showMessage('拉取成功（已覆盖本地）');
      setState(() => _processing = false);
      return;
    }

    setState(() => _processing = false);
    if (result.notFound) {
      _showMessage('远端不存在该日记文件');
      return;
    }
    _showMessage(result.error ?? '拉取失败');
  }

  Future<void> _pushDiary() async {
    final ok = await _ensureToken();
    if (!ok) return;

    _startedAt ??= DateTime.now();
    await _saveDraftNow();

    setState(() => _processing = true);
    final fileName = _buildFileName();
    final markdown = _buildMarkdownContent();
    final result = await DiaryGitHubService.pushDiary(
      token: _token!,
      path: fileName,
      content: markdown,
      commitMessage: 'diary: update $fileName',
    );
    if (!mounted) return;
    setState(() => _processing = false);

    if (result.success) {
      _showMessage(result.created ? '同步成功（已新建远端文件）' : '同步成功');
      return;
    }
    _showMessage(result.error ?? '同步失败');
  }

  Future<void> _editToken() async {
    final controller = TextEditingController(text: _token ?? '');
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('修改 GitHub Token'),
          content: TextField(
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '粘贴新的 Personal Access Token',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (token == null || token.isEmpty) return;
    _token = token;
    await DiaryLocalStore.saveToken(token);
    _showMessage('Token 已更新');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final startedAt = _startedAt;
    final hasToken = (_token ?? '').trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('日记'),
        actions: [
          IconButton(
            tooltip: '浏览远程日记',
            onPressed: _processing ? null : _browseRemoteDiaries,
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: '拉取日记',
            onPressed: _processing ? null : _pullDiary,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: '同步日记',
            onPressed: _processing ? null : _pushDiary,
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: hasToken ? '修改 Token' : '设置 Token',
            onPressed: _processing ? null : _editToken,
            icon: Icon(hasToken ? Icons.vpn_key : Icons.key_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ChoiceChip(
                  label: const Text('G'),
                  selected: _kind == DiaryKind.g,
                  onSelected: (_) => _changeKind(DiaryKind.g),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('J'),
                  selected: _kind == DiaryKind.j,
                  onSelected: (_) => _changeKind(DiaryKind.j),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _processing ? null : _pickDate,
                  icon: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(_selectedDateText()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: startedAt == null
                  ? const Text(
                      '开始输入正文后，会自动生成 title 与 date。',
                      style: TextStyle(color: Colors.black54),
                    )
                  : Text(
                      'title: ${_frontMatterTitle(startedAt)}\n'
                      'date: ${_frontMatterDate(startedAt)}',
                      style: const TextStyle(height: 1.5),
                    ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _bodyController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: '在这里写正文...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
