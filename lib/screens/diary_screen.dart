import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/diary_kind.dart';
import '../models/diary_search_result.dart';
import '../services/diary_gitee_service.dart';
import '../services/diary_local_store.dart';
import '../services/diary_search_service.dart';
import 'diary_search_screen.dart';

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
  DateTime? _remoteDiaryPathsFetchedAt;
  final Set<String> _expandedRemoteFolders = {};
  final Map<String, String> _contextRemotePathOverrides = {};
  bool _lastContextPathAmbiguous = false;
  int _contextRequestId = 0;
  bool _dirtySinceContextLoaded = false;
  static const Duration _remotePathsTtl = Duration(minutes: 3);
  Set<String> _gDiaryDateKeys = {};
  Set<String> _jDiaryDateKeys = {};

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
    _dirtySinceContextLoaded = false;
    if (!mounted) return;
    setState(() => _loading = false);
    _refreshCurrentContextFromRemote(_contextRequestId, forcePathRefresh: false);

    // 后台加载搜索缓存
    if (token != null && token.isNotEmpty) {
      DiarySearchService.loadInBackground(token);
    }
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
        '\n'
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

  bool _isRemotePathsCacheFresh() {
    if (_remoteDiaryPathsFetchedAt == null || _remoteDiaryPaths.isEmpty) {
      return false;
    }
    return DateTime.now().difference(_remoteDiaryPathsFetchedAt!) < _remotePathsTtl;
  }

  void _updateDiaryDateKeys() {
    final gKeys = <String>{};
    final jKeys = <String>{};
    for (final path in _remoteDiaryPaths) {
      final date = _parseDateFromPath(path);
      if (date != null) {
        final dateKey = DateFormat('yyyy-MM-dd').format(date);
        final fileName = _fileNameFromPath(path);
        if (fileName.startsWith('G')) {
          gKeys.add(dateKey);
        } else if (fileName.startsWith('J')) {
          jKeys.add(dateKey);
        }
      }
    }
    _gDiaryDateKeys = gKeys;
    _jDiaryDateKeys = jKeys;
  }

  Future<List<String>?> _fetchRemoteDiaryPathsSilently({
    bool forceRefresh = false,
  }) async {
    final token = (_token ?? '').trim();
    if (token.isEmpty) return null;
    if (!forceRefresh && _isRemotePathsCacheFresh()) {
      return _remoteDiaryPaths;
    }
    final listResult = await DiaryGiteeService.listDiaryPaths(token: token);
    if (!listResult.success) return null;
    _remoteDiaryPaths = listResult.paths;
    _remoteDiaryPathsFetchedAt = DateTime.now();
    _updateDiaryDateKeys();
    return listResult.paths;
  }

  Future<String?> _findRemotePathForCurrentContext({bool refresh = true}) async {
    List<String> paths = _remoteDiaryPaths;
    if (refresh || paths.isEmpty) {
      final fetched = await _fetchRemoteDiaryPathsSilently(forceRefresh: refresh);
      if (fetched != null) {
        paths = fetched;
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
    _dirtySinceContextLoaded = true;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 350), () {
      _saveDraftNow();
      if (mounted) setState(() {});
    });
  }

  Future<void> _switchContext({
    DiaryKind? kind,
    DateTime? date,
  }) async {
    await _saveDraftNow();
    _contextRequestId++;
    final requestId = _contextRequestId;

    if (kind != null) {
      _kind = kind;
      await DiaryLocalStore.savePreferredKind(kind);
    }
    if (date != null) {
      _selectedDate = DateTime(date.year, date.month, date.day);
    }

    await _loadDraftForCurrentContext();
    _dirtySinceContextLoaded = false;
    if (!mounted || requestId != _contextRequestId) return;
    setState(() {});

    _refreshCurrentContextFromRemote(requestId, forcePathRefresh: false);
  }

  Future<void> _refreshCurrentContextFromRemote(
    int requestId, {
    required bool forcePathRefresh,
  }) async {
    final token = (_token ?? '').trim();
    if (token.isEmpty) return;
    if (!mounted || requestId != _contextRequestId) return;

    var remotePath =
        await _findRemotePathForCurrentContext(refresh: forcePathRefresh);
    if (!mounted || requestId != _contextRequestId) return;
    if (remotePath == null && !forcePathRefresh) {
      // 缓存没命中时再强制刷新一次远程列表。
      remotePath = await _findRemotePathForCurrentContext(refresh: true);
      if (!mounted || requestId != _contextRequestId) return;
    }
    if (remotePath == null) return;

    // 优先从搜索缓存读取
    String? raw = DiarySearchService.getCachedContentByPath(remotePath);

    if (raw == null) {
      final result = await DiaryGiteeService.pullDiary(token: token, path: remotePath);
      if (!mounted || requestId != _contextRequestId) return;
      if (!result.success) return;
      if (_dirtySinceContextLoaded) return;
      raw = result.content!;
    }

    if (_dirtySinceContextLoaded) return;
    final body = _extractBodyFromMarkdown(raw);
    final startedAt = _parseStartedAtFromMarkdown(raw);
    _suppressBodyListener = true;
    _bodyController.text = body;
    _suppressBodyListener = false;
    _startedAt = startedAt ?? DateTime.now();
    _contextRemotePathOverrides[_contextKey(_kind, _selectedDate)] = remotePath;
    await _saveDraftNow();
    if (!mounted || requestId != _contextRequestId) return;
    setState(() {});
  }

  void _onDateSelected(DateTime date) async {
    Navigator.pop(context);
    await _switchContext(date: DateTime(date.year, date.month, date.day));
  }

  void _showCalendarPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CalendarPickerSheet(
        selectedDate: _selectedDate,
        gDiaryDateKeys: _gDiaryDateKeys,
        jDiaryDateKeys: _jDiaryDateKeys,
        onDateSelected: _onDateSelected,
      ),
    );
  }

  Future<void> _changeKind(DiaryKind kind) async {
    if (_kind == kind) return;
    await _switchContext(kind: kind);
  }

  Future<void> _openSearch() async {
    final token = (_token ?? '').trim();
    if (token.isEmpty) {
      _showMessage('请先配置当前平台同步 Token');
      return;
    }

    // 如果索引未加载且未在加载中，触发加载
    if (!DiarySearchService.isLoaded && !DiarySearchService.isLoading) {
      DiarySearchService.loadInBackground(token);
    }

    if (!mounted) return;

    final result = await Navigator.push<DiarySearchResult>(
      context,
      MaterialPageRoute(builder: (_) => const DiarySearchScreen()),
    );

    if (result != null && mounted) {
      await _switchContext(
        kind: result.kind == 'g' ? DiaryKind.g : DiaryKind.j,
        date: result.date,
      );
    }
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
    // 优先从搜索缓存读取
    String? raw = DiarySearchService.getCachedContentByPath(path);

    if (raw == null) {
    // 缓存未命中，从远程仓库拉取
      final result = await DiaryGiteeService.pullDiary(token: _token!, path: path);
      if (!mounted) return;
      if (!result.success) {
        _showMessage(result.error ?? '加载远程文件失败');
        return;
      }
      raw = result.content!;
    }

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
    _contextRequestId++;
    _dirtySinceContextLoaded = false;

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
      _remoteTreeError = '未配置当前平台同步 Token';
        _remoteTreeLoading = false;
      });
      return;
    }
    setState(() {
      _remoteTreeLoading = true;
      _remoteTreeError = null;
    });
    final listResult = await DiaryGiteeService.listDiaryPaths(token: _token!);
    if (!mounted) return;
    setState(() {
      _remoteTreeLoading = false;
      if (listResult.success) {
        _remoteDiaryPaths = listResult.paths;
        _remoteDiaryPathsFetchedAt = DateTime.now();
        _remoteTreeError = null;
        _updateDiaryDateKeys();
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
    _showMessage('未配置当前平台同步 Token，请在对应配置文件里设置 hardcodedToken');
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
    final result = await DiaryGiteeService.pullDiary(
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
    final result = await DiaryGiteeService.pushDiary(
      token: _token!,
      path: fileName,
      content: markdown,
      commitMessage: 'diary: update $fileName',
    );
    if (!mounted) return;
    setState(() => _processing = false);

    if (result.success) {
      // 后台更新搜索缓存
      DiarySearchService.loadInBackground(_token!);
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
    final colorScheme = Theme.of(context).colorScheme;

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
            tooltip: '搜索日记',
            onPressed: _openSearch,
            icon: const Icon(Icons.search),
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
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
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
                  onPressed: _processing ? null : _showCalendarPicker,
                  icon: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(_selectedDateText()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: startedAt == null
                  ? Text(
                      '开始输入正文后，会自动生成 title 与 date。',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    )
                  : Text(
                      'title: ${_frontMatterTitle(startedAt)}\n'
                      'date: ${_frontMatterDate(startedAt)}',
                      style: TextStyle(
                        height: 1.5,
                        color: colorScheme.onSurface,
                      ),
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
      ),
          ValueListenableBuilder<double>(
            valueListenable: DiarySearchService.progress,
            builder: (context, value, child) {
              if (value >= 1.0 || !DiarySearchService.isLoading) {
                return const SizedBox.shrink();
              }
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: colorScheme.surfaceContainerHigh,
                child: Row(
                  children: [
                    Icon(Icons.search, size: 16, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: value > 0 ? value : null,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      value > 0 ? '${(value * 100).toInt()}%' : '准备中...',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
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

class _CalendarPickerSheet extends StatefulWidget {
  const _CalendarPickerSheet({
    required this.selectedDate,
    required this.gDiaryDateKeys,
    required this.jDiaryDateKeys,
    required this.onDateSelected,
  });

  final DateTime selectedDate;
  final Set<String> gDiaryDateKeys;
  final Set<String> jDiaryDateKeys;
  final Function(DateTime) onDateSelected;

  @override
  State<_CalendarPickerSheet> createState() => _CalendarPickerSheetState();
}

class _CalendarPickerSheetState extends State<_CalendarPickerSheet> {
  late DateTime _calendarMonth;

  @override
  void initState() {
    super.initState();
    _calendarMonth = DateTime(
      widget.selectedDate.year,
      widget.selectedDate.month,
      1,
    );
  }

  void _changeMonth(int delta) {
    setState(() {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month + delta,
        1,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final year = _calendarMonth.year;
    final month = _calendarMonth.month;
    final firstDayOfMonth = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final startWeekday = firstDayOfMonth.weekday;
    final today = DateTime.now();
    final todayKey = DateFormat('yyyy-MM-dd').format(today);
    final selectedKey = DateFormat('yyyy-MM-dd').format(widget.selectedDate);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed: () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Text(
                '$year年$month月',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              IconButton(
                onPressed: () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: ['一', '二', '三', '四', '五', '六', '日']
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.0,
            children: List.generate(42, (index) {
              final dayOffset = index - (startWeekday - 1);
              if (dayOffset < 0 || dayOffset >= daysInMonth) {
                return const SizedBox.shrink();
              }
              final day = dayOffset + 1;
              final date = DateTime(year, month, day);
              final dateKey = DateFormat('yyyy-MM-dd').format(date);
              final isSelected = dateKey == selectedKey;
              final isToday = dateKey == todayKey;
              final hasGDiary = widget.gDiaryDateKeys.contains(dateKey);
              final hasJDiary = widget.jDiaryDateKeys.contains(dateKey);
              final hasDiary = hasGDiary || hasJDiary;

              return GestureDetector(
                onTap: () => widget.onDateSelected(date),
                child: Container(
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: isSelected ? colorScheme.primaryContainer : null,
                    border: isToday
                        ? Border.all(color: colorScheme.primary, width: 1.5)
                        : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$day',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected
                              ? colorScheme.onPrimaryContainer
                              : null,
                        ),
                      ),
                      if (hasDiary)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (hasGDiary)
                              Container(
                                margin:
                                    const EdgeInsets.only(top: 2, right: 1),
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF4DA8EE),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            if (hasJDiary)
                              Container(
                                margin:
                                    const EdgeInsets.only(top: 2, left: 1),
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF16B77),
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF4DA8EE),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              const Text('G', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 16),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFFF16B77),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              const Text('J', style: TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
