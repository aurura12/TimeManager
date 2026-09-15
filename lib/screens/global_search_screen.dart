import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/global_search_result.dart';
import '../providers/time_provider.dart';
import '../services/unified_search_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'event_detail_screen.dart';
import 'global_search_detail_screen.dart';
import 'target_detail_screen.dart';

enum _SearchDateRange { all, week, month, year, custom }

/// 统一搜索入口。
///
/// 默认只读取本地数据。传入 [initialIndex] 主要用于 widget 测试，生产入口
/// 由当前 [TimeProvider] 创建 [UnifiedSearchService]。
class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({
    super.key,
    this.searchService,
    this.initialIndex,
  });

  final UnifiedSearchService? searchService;
  final GlobalSearchIndex? initialIndex;

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  _SearchDateRange _dateRange = _SearchDateRange.all;
  GlobalSearchContentType _contentType = GlobalSearchContentType.all;
  GlobalSearchIdentityFilter _identity = GlobalSearchIdentityFilter.all;
  DateTime? _customStart;
  DateTime? _customEnd;
  List<GlobalSearchResult> _results = const [];
  List<String> _recentSearches = const [];
  String _query = '';
  String? _loadError;
  Timer? _debounceTimer;
  late final UnifiedSearchService _searchService;
  int _searchRevision = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _searchService = widget.searchService ??
        UnifiedSearchService(
          timeProvider: context.read<TimeProvider>(),
        );
    _controller.addListener(_onQueryChanged);
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final recent = await _searchService.loadRecentSearches();
      await _searchService.loadLocalIndex();
      if (!mounted) return;
      setState(() {
        _recentSearches = recent;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '本地搜索数据加载失败：$error';
      });
    }
  }

  void _onQueryChanged() {
    final query = _controller.text;
    if (mounted) {
      setState(() => _query = query);
    }
    _debounceTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 260), () {
      unawaited(_runSearch(query));
    });
  }

  Future<void> _runSearch([String? queryOverride]) async {
    final query = (queryOverride ?? _controller.text).trim();
    final revision = ++_searchRevision;
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() => _results = const []);
      return;
    }

    if (mounted) setState(() => _loading = true);
    try {
      final results = await _searchService.search(
        query,
        contentType: _contentType,
        identity: _identity,
        startDate: _rangeStart(),
        endDate: _rangeEnd(),
      );
      if (!mounted || revision != _searchRevision) return;
      setState(() {
        _query = query;
        _results = results;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted || revision != _searchRevision) return;
      setState(() {
        _results = const [];
        _loading = false;
        _loadError = '搜索失败：$error';
      });
    }
  }

  Future<void> _rememberCurrentSearch() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    await _searchService.rememberSearch(query);
    if (!mounted) return;
    final recent = await _searchService.loadRecentSearches();
    if (mounted) setState(() => _recentSearches = recent);
  }

  DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime? _rangeStart() {
    switch (_dateRange) {
      case _SearchDateRange.all:
        return null;
      case _SearchDateRange.week:
        return _today().subtract(const Duration(days: 6));
      case _SearchDateRange.month:
        return _today().subtract(const Duration(days: 29));
      case _SearchDateRange.year:
        return _today().subtract(const Duration(days: 364));
      case _SearchDateRange.custom:
        return _customStart;
    }
  }

  DateTime? _rangeEnd() {
    if (_dateRange == _SearchDateRange.custom) return _customEnd;
    if (_dateRange == _SearchDateRange.all) return null;
    return _today();
  }

  void _selectRecent(String query) {
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
  }

  void _changeType(GlobalSearchContentType value) {
    if (_contentType == value) return;
    setState(() => _contentType = value);
    unawaited(_runSearch());
  }

  void _changeIdentity(GlobalSearchIdentityFilter value) {
    if (_identity == value) return;
    setState(() => _identity = value);
    unawaited(_runSearch());
  }

  void _changeDateRange(_SearchDateRange range) {
    if (range == _SearchDateRange.custom) {
      unawaited(_pickCustomDateRange());
      return;
    }
    setState(() => _dateRange = range);
    unawaited(_runSearch());
  }

  Future<void> _pickCustomDateRange() async {
    final now = _today();
    final initialStart = _customStart ?? now.subtract(const Duration(days: 29));
    final initialEnd = _customEnd ?? now;
    final initialRange = DateTimeRange(
      start: initialStart.isAfter(initialEnd) ? initialEnd : initialStart,
      end: initialEnd,
    );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: initialRange,
      locale: const Locale('zh'),
      helpText: '选择搜索日期范围',
    );
    if (!mounted || picked == null) return;
    setState(() {
      _dateRange = _SearchDateRange.custom;
      _customStart = DateTime(
        picked.start.year,
        picked.start.month,
        picked.start.day,
      );
      _customEnd = DateTime(
        picked.end.year,
        picked.end.month,
        picked.end.day,
      );
    });
    await _runSearch();
  }

  String _dateText(DateTime? date) {
    if (date == null) return '未标记日期';
    return '${date.year}年${date.month}月${date.day}日';
  }

  String _dateRangeLabel() {
    if (_dateRange != _SearchDateRange.custom) {
      return switch (_dateRange) {
        _SearchDateRange.all => '全部日期',
        _SearchDateRange.week => '近 7 天',
        _SearchDateRange.month => '近 30 天',
        _SearchDateRange.year => '近一年',
        _SearchDateRange.custom => '自定义',
      };
    }
    if (_customStart == null || _customEnd == null) return '自定义日期';
    return '${_customStart!.month}/${_customStart!.day}-'
        '${_customEnd!.month}/${_customEnd!.day}';
  }

  Future<void> _openResult(GlobalSearchResult result) async {
    await _rememberCurrentSearch();
    if (!mounted) return;

    final provider = context.read<TimeProvider>();
    switch (result.type) {
      case GlobalSearchContentType.all:
        await _pushLocalDetail(result);
        return;
      case GlobalSearchContentType.timeRecord:
        final date = result.date;
        if (date != null) provider.goToDate(date);
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        return;
      case GlobalSearchContentType.category:
        // 当前身份的分类可以复用现有事件历史详情；另一身份的本地分类不
        // 冒充当前 Provider 数据，改走只读本地详情页。
        if (result.identityKind == null ||
            result.identityKind == provider.scheduleUser) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => EventDetailScreen(
                eventName: result.title,
                tabIndex: 0,
              ),
            ),
          );
        } else {
          await _pushLocalDetail(result);
        }
        return;
      case GlobalSearchContentType.target:
        if (result.entityId != null &&
            provider.targetById(result.entityId!) != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TargetDetailScreen(targetId: result.entityId!),
            ),
          );
        } else {
          await _pushLocalDetail(result);
        }
        return;
      case GlobalSearchContentType.diary:
      case GlobalSearchContentType.travel:
      case GlobalSearchContentType.checkIn:
        await _pushLocalDetail(result);
        return;
    }
  }

  Future<void> _pushLocalDetail(GlobalSearchResult result) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GlobalSearchDetailScreen(result: result),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => unawaited(_rememberCurrentSearch()),
          style: AppText.body.copyWith(color: colorScheme.onSurface),
          decoration: InputDecoration(
            hintText: '搜索时间、日记、出行、打卡或目标…',
            hintStyle: AppText.body.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            border: InputBorder.none,
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    tooltip: '清除搜索',
                    icon: Icon(
                      Icons.clear,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    onPressed: _controller.clear,
                  )
                : null,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildFilterBar(colorScheme),
          if (_query.trim().isNotEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Text(
                '共 ${_results.length} 条结果',
                style: AppText.caption.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? _buildLoading(colorScheme)
                : _query.trim().isEmpty
                    ? _buildRecentSearches(colorScheme, surfaces)
                    : _results.isEmpty
                        ? _buildEmpty(colorScheme)
                        : _buildResults(colorScheme, surfaces),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildFilterRow(
            label: '内容',
            children: GlobalSearchContentType.values.map((type) {
              return _filterChip(
                label: type.label,
                selected: _contentType == type,
                onSelected: () => _changeType(type),
                colorScheme: colorScheme,
              );
            }).toList(),
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildFilterRow(
            label: '身份',
            children: GlobalSearchIdentityFilter.values.map((identity) {
              return _filterChip(
                label: identity.label,
                selected: _identity == identity,
                onSelected: () => _changeIdentity(identity),
                colorScheme: colorScheme,
              );
            }).toList(),
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildFilterRow(
            label: '日期',
            children: [
              for (final entry in <(_SearchDateRange, String)>[
                (_SearchDateRange.all, '全部日期'),
                (_SearchDateRange.week, '近 7 天'),
                (_SearchDateRange.month, '近 30 天'),
                (_SearchDateRange.year, '近一年'),
                (_SearchDateRange.custom, _dateRangeLabel()),
              ])
                _filterChip(
                  label: entry.$2,
                  selected: _dateRange == entry.$1,
                  onSelected: () => _changeDateRange(entry.$1),
                  colorScheme: colorScheme,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow({
    required String label,
    required List<Widget> children,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: AppSizes.listRow,
          height: AppSizes.minTapTarget,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(label, style: AppText.caption),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.sm),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
    required ColorScheme colorScheme,
  }) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      visualDensity: VisualDensity.compact,
      selectedColor: colorScheme.primaryContainer,
      checkmarkColor: colorScheme.onPrimaryContainer,
      labelStyle: AppText.badge.copyWith(
        color:
            selected ? colorScheme.onPrimaryContainer : colorScheme.onSurface,
      ),
    );
  }

  Widget _buildLoading(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: AppSizes.iconButton,
            height: AppSizes.iconButton,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            _loadError ?? '正在搜索本地数据…',
            style: AppText.body.copyWith(color: colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildRecentSearches(
    ColorScheme colorScheme,
    AppSurfaces surfaces,
  ) {
    if (_recentSearches.isEmpty) {
      return _buildCenteredMessage(
        icon: Icons.search,
        message: _loadError ?? '输入关键词搜索本地时间、日记、出行、打卡和目标',
        colorScheme: colorScheme,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '最近搜索',
                style: AppText.sectionTitle.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                await _searchService.clearRecentSearches();
                if (mounted) setState(() => _recentSearches = const []);
              },
              child: const Text('清空'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final query in _recentSearches)
              ActionChip(
                label: Text(query),
                avatar: Icon(
                  Icons.history,
                  size: AppText.body.fontSize,
                  color: colorScheme.onSurfaceVariant,
                ),
                backgroundColor: surfaces.card,
                side: BorderSide(color: surfaces.border),
                onPressed: () => _selectRecent(query),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmpty(ColorScheme colorScheme) {
    return _buildCenteredMessage(
      icon: Icons.search_off,
      message: '未找到「$_query」相关本地内容',
      colorScheme: colorScheme,
      secondary: '可尝试切换内容、身份或日期筛选',
    );
  }

  Widget _buildCenteredMessage({
    required IconData icon,
    required String message,
    required ColorScheme colorScheme,
    String? secondary,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: AppSizes.iconButton,
              color: colorScheme.outlineVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              style: AppText.body.copyWith(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            if (secondary != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                secondary,
                style: AppText.caption.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ColorScheme colorScheme, AppSurfaces surfaces) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final result = _results[index];
        final identityColor = result.identityKind == null
            ? colorScheme.primary
            : result.identityKind!.name == 'g'
                ? AppSemanticColors.identityGuaiGuai
                : AppSemanticColors.identityJingJing;
        return Semantics(
          button: true,
          label:
              '${result.moduleLabel}，${result.title}，${_dateText(result.date)}',
          child: Material(
            color: surfaces.card,
            borderRadius: AppRadius.cardAll,
            child: InkWell(
              borderRadius: AppRadius.cardAll,
              onTap: () => unawaited(_openResult(result)),
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  borderRadius: AppRadius.cardAll,
                  border: Border.all(color: surfaces.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: AppSpacing.sm,
                      height: AppSpacing.sm,
                      margin: const EdgeInsets.only(top: AppSpacing.xs),
                      decoration: BoxDecoration(
                        color: identityColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Text(
                                result.moduleLabel,
                                style: AppText.badge.copyWith(
                                  color: colorScheme.primary,
                                ),
                              ),
                              if (result.identityLabel != null) ...[
                                const SizedBox(width: AppSpacing.sm),
                                Text(
                                  result.identityLabel!,
                                  style: AppText.caption.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              const Spacer(),
                              Text(
                                _dateText(result.date),
                                style: AppText.caption.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            result.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.body.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            result.summary,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Icon(
                      Icons.chevron_right,
                      size: AppSizes.iconButton,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
