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
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  DiaryKind _kind = DiaryKind.g;
  DateTime _selectedDate = DateTime.now();
  DateTime? _startedAt;
  String? _token;
  bool _loading = true;
  bool _processing = false;
  bool _suppressBodyListener = false;
  Timer? _saveDebounce;
  bool _remoteTreeLoading = false;
  String? _remoteTreeError;
  List<String> _remoteDiaryPaths = const [];
  final Set<String> _expandedRemoteFolders = {};
  final Map<String, String> _contextRemotePathOverrides = {};
  bool _lastContextPathAmbiguous = false;

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

  String _dateTextForFile(DateTime date) {
    return DateFormat('yyyy年M月d日').format(date);
  }

  String _contextKey(DiaryKind kind, DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${kind.code}_${d.year}$month$day';
  }

  String _kindLetter(DiaryKind kind) {
    return kind == DiaryKind.g ? 'G' : 'J';
  }

  String _fileNameFromPath(String path) {
    final segments = path.split('/');
    return segments.isEmpty ? path : segments.last;
  }

  bool _matchesKindAndDate(String path, DiaryKind kind, DateTime date) {
    final fileName = _fileNameFromPath(path);
    if (!fileName.toLowerCase().endsWith('.md')) return false;
    if (!fileName.startsWith(_kindLetter(kind))) return false;
    return fileName.contains(_dateTextForFile(date));
  }

  Future<List<String>?> _fetchRemoteDiaryPathsSilently() async {
    final token = (_token ?? '').trim();
    if (token.isEmpty) return null;
    final listResult = await DiaryGitHubService.listDiaryPaths(token: token);
    if (!listResult.success) return null;
    return listResult.paths;
  }

  Future<String?> _findRemotePathForCurrentContext({bool refresh = true}) async {
    List<String> paths = _remoteDiaryPaths;
    if (refresh || paths.isEmpty) {
      final fetched = await _fetchRemoteDiaryPathsSilently();
      if (fetched != null) {
        paths = fetched;
        _remoteDiaryPaths = fetched;
      }
    }
    if (paths.isEmpty) return null;

    final matched =
        paths.where((p) => _matchesKindAndDate(p, _kind, _selectedDate)).toList();
    if (matched.isEmpty) return null;
    final pinned = _contextRemotePathOverrides[_contextKey(_kind, _selectedDate)];
    if (pinned != null && matched.contains(pinned)) {
      _lastContextPathAmbiguous = false;
      return pinned;
    }
    if (matched.length > 1) {
      _lastContextPathAmbiguous = true;
      return null;
    }
    _lastContextPathAmbiguous = false;
    return matched.first;
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

  Future<void> _loadContextWithRemoteFallback() async {
    final token = (_token ?? '').trim();
    if (token.isNotEmpty) {
      final remotePath = await _findRemotePathForCurrentContext(refresh: true);
      if (remotePath != null) {
        final result =
            await DiaryGitHubService.pullDiary(token: token, path: remotePath);
        if (result.success) {
          final raw = result.content!;
          final body = _extractBodyFromMarkdown(raw);
          final startedAt = _parseStartedAtFromMarkdown(raw);
          _suppressBodyListener = true;
          _bodyController.text = body;
          _suppressBodyListener = false;
          _startedAt = startedAt ?? DateTime.now();
          await _saveDraftNow();
          return;
        }
      }
    }

    // 远程不存在或拉取失败时，回退本地草稿。
    await _loadDraftForCurrentContext();
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
    setState(() => _processing = true);
    _selectedDate = DateTime(picked.year, picked.month, picked.day);
    await _loadContextWithRemoteFallback();
    if (!mounted) return;
    setState(() => _processing = false);
  }

  Future<void> _changeKind(DiaryKind kind) async {
    if (_kind == kind) return;
    await _saveDraftNow();
    setState(() => _processing = true);
    _kind = kind;
    await DiaryLocalStore.savePreferredKind(kind);
    await _loadContextWithRemoteFallback();
    if (!mounted) return;
    setState(() => _processing = false);
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

  DateTime? _parseDateFromPath(String path) {
    final fileName = _fileNameFromPath(path);
    final match = RegExp(r'(\d{4})年(\d{1,2})月(\d{1,2})日').firstMatch(fileName);
    if (match == null) return null;
    final year = int.tryParse(match.group(1) ?? '');
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
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
    final parsedDate = _parseDateFromPath(path);
    if (parsedDate != null) {
      _selectedDate = DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
    }
    _contextRemotePathOverrides[_contextKey(_kind, _selectedDate)] = path;

    _suppressBodyListener = true;
    _bodyController.text = body;
    _suppressBodyListener = false;
    _startedAt = startedAt ?? DateTime.now();
    await _saveDraftNow();
    setState(() {});
    _showMessage('已载入：$path');
  }

  Future<void> _loadRemoteTree() async {
    if ((_token ?? '').trim().isEmpty) {
      setState(() {
        _remoteTreeError = '未配置 GitHub Token';
        _remoteTreeLoading = false;
      });
      return;
    }
    setState(() {
      _remoteTreeLoading = true;
      _remoteTreeError = null;
    });
    final listResult = await DiaryGitHubService.listDiaryPaths(token: _token!);
    if (!mounted) return;
    setState(() {
      _remoteTreeLoading = false;
      if (listResult.success) {
        _remoteDiaryPaths = listResult.paths;
        _remoteTreeError = null;
      } else {
        _remoteTreeError = listResult.error ?? '读取远程列表失败';
      }
    });
  }

  Future<void> _openRemoteTreeDrawer() async {
    if (_processing) return;
    _scaffoldKey.currentState?.openDrawer();
    if (_remoteTreeLoading) return;
    if (_remoteDiaryPaths.isNotEmpty && _remoteTreeError == null) return;
    await _loadRemoteTree();
  }

  Future<bool> _ensureToken() async {
    final token = (_token ?? '').trim();
    if (token.isNotEmpty) return true;
    _showMessage('未配置 GitHub Token，请在 diary_github_config.dart 里设置 hardcodedToken');
    return false;
  }

  Future<void> _openPathFromTree(String path) async {
    Navigator.of(context).pop();
    await _saveDraftNow();
    setState(() => _processing = true);
    await _loadRemoteFileToEditor(path);
    if (!mounted) return;
    setState(() => _processing = false);
  }

  List<_RemoteFileNode> _buildRemoteTree(List<String> paths) {
    final root = <String, _RemoteFileNode>{};
    for (final path in paths) {
      final segments = path.split('/').where((e) => e.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      Map<String, _RemoteFileNode> current = root;
      var currentPath = '';
      for (int i = 0; i < segments.length; i++) {
        final name = segments[i];
        currentPath = currentPath.isEmpty ? name : '$currentPath/$name';
        final isFile = i == segments.length - 1;
        final node = current.putIfAbsent(
          name,
          () => _RemoteFileNode(
            name: name,
            path: currentPath,
            isFile: isFile,
          ),
        );
        node.isFile = node.isFile && isFile;
        current = node.children;
      }
    }
    final list = root.values.toList();
    list.sort(_sortRemoteNodes);
    for (final node in list) {
      _sortChildren(node);
    }
    return list;
  }

  void _sortChildren(_RemoteFileNode node) {
    final children = node.children.values.toList();
    children.sort(_sortRemoteNodes);
    node.sortedChildren = children;
    for (final child in children) {
      _sortChildren(child);
    }
  }

  int _sortRemoteNodes(_RemoteFileNode a, _RemoteFileNode b) {
    if (a.isFile == b.isFile) {
      return a.name.compareTo(b.name);
    }
    return a.isFile ? 1 : -1;
  }

  Widget _buildRemoteNodeWidget(_RemoteFileNode node) {
    if (node.isFile) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.description_outlined, size: 18),
        title: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(node.path, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => _openPathFromTree(node.path),
      );
    }
    final expanded = _expandedRemoteFolders.contains(node.path);
    return ExpansionTile(
      key: ValueKey(node.path),
      initiallyExpanded: expanded,
      leading: const Icon(Icons.folder_outlined, size: 18),
      title: Text(node.name),
      childrenPadding: const EdgeInsets.only(left: 12),
      onExpansionChanged: (value) {
        setState(() {
          if (value) {
            _expandedRemoteFolders.add(node.path);
          } else {
            _expandedRemoteFolders.remove(node.path);
          }
        });
      },
      children: [
        for (final child in node.sortedChildren) _buildRemoteNodeWidget(child),
      ],
    );
  }

  Widget _buildRemoteTreeContent() {
    if (_remoteTreeLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_remoteTreeError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_remoteTreeError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _loadRemoteTree,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_remoteDiaryPaths.isEmpty) {
      return const Center(child: Text('远程仓库未找到 G/J 日记文件'));
    }
    final roots = _buildRemoteTree(_remoteDiaryPaths);
    return ListView(
      children: [
        for (final node in roots) _buildRemoteNodeWidget(node),
      ],
    );
  }

  Future<void> _pullDiary() async {
    final ok = await _ensureToken();
    if (!ok) return;

    setState(() => _processing = true);
    final path = await _findRemotePathForCurrentContext(refresh: true);
    if (path == null && _lastContextPathAmbiguous) {
      setState(() => _processing = false);
      _showMessage('该日期命中多个远程文件，请从左侧文件树点开目标文件');
      return;
    }
    final targetPath = path ?? _buildFileName();
    final result = await DiaryGitHubService.pullDiary(
      token: _token!,
      path: targetPath,
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
    final remotePath = await _findRemotePathForCurrentContext(refresh: true);
    if (remotePath == null && _lastContextPathAmbiguous) {
      setState(() => _processing = false);
      _showMessage('该日期命中多个远程文件，请先从左侧文件树点开后再同步');
      return;
    }
    final fileName = remotePath ?? _buildFileName();
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

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
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

    return Scaffold(
      key: _scaffoldKey,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: const Text('远程日记文件树'),
                trailing: IconButton(
                  tooltip: '刷新',
                  onPressed: _remoteTreeLoading ? null : _loadRemoteTree,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _buildRemoteTreeContent()),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        title: const Text('日记'),
        leading: IconButton(
          tooltip: '浏览远程日记',
          onPressed: _openRemoteTreeDrawer,
          icon: const Icon(Icons.menu),
        ),
        actions: [
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

class _RemoteFileNode {
  final String name;
  final String path;
  bool isFile;
  final Map<String, _RemoteFileNode> children;
  List<_RemoteFileNode> sortedChildren;

  _RemoteFileNode({
    required this.name,
    required this.path,
    required this.isFile,
  })  : children = <String, _RemoteFileNode>{},
        sortedChildren = const [];
}
