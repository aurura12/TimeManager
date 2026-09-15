import 'package:flutter/material.dart';
import '../services/daily_review_summary.dart';
import '../widgets/daily_review_chat_sheet.dart';

import '../theme/app_tokens.dart';

class DailyReviewScreen extends StatefulWidget {
  final DateTime date;

  const DailyReviewScreen({
    super.key,
    required this.date,
  });

  static Future<void> open(
    BuildContext context, {
    DateTime? date,
  }) {
    final target = date ?? DateTime.now();
    final normalized = DateTime(target.year, target.month, target.day);
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DailyReviewScreen(date: normalized),
      ),
    );
  }

  @override
  State<DailyReviewScreen> createState() => _DailyReviewScreenState();
}

class _DailyReviewScreenState extends State<DailyReviewScreen> {
  static final _earliestDate = DateTime(2020, 1, 1);
  static const _dateItemExtent = 62.0;
  static const _initialDays = 30;
  static const _appendDays = 30;
  static const _estimatedCardHeight = 280.0;

  final ScrollController _leftController = ScrollController();
  final ScrollController _rightController = ScrollController();
  final List<_ReviewEntry> _entries = [];
  final List<GlobalKey> _cardKeys = [];

  late DateTime _selectedDate;
  bool _loadingMore = false;
  bool _aiEnabled = true;
  bool _aiConsent = false;
  bool _aiSettingsReady = false;
  bool _aiConsentDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = _normalizeDate(widget.date);
    _appendRecentDays(_initialDays);
    _ensureDateLoaded(_selectedDate);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollLeftToSelected(jump: true);
      _jumpRightToDate(_selectedDate, jump: true);
      _initializeAi();
    });
  }

  @override
  void dispose() {
    _leftController.dispose();
    _rightController.dispose();
    super.dispose();
  }

  DateTime _normalizeDate(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  int _indexOfDate(DateTime date) =>
      _entries.indexWhere((e) => _sameDate(e.date, date));

  void _appendRecentDays(int count) {
    if (_entries.isNotEmpty) return;
    final today = _normalizeDate(DateTime.now());
    var cursor = today;
    for (var i = 0; i < count && !cursor.isBefore(_earliestDate); i++) {
      _entries.add(_ReviewEntry(date: cursor));
      _cardKeys.add(GlobalKey());
      cursor = cursor.subtract(const Duration(days: 1));
    }
  }

  void _appendOlderDays(int count) {
    if (_entries.isEmpty) return;
    var cursor = _entries.last.date.subtract(const Duration(days: 1));
    for (var i = 0; i < count && !cursor.isBefore(_earliestDate); i++) {
      _entries.add(_ReviewEntry(date: cursor));
      _cardKeys.add(GlobalKey());
      cursor = cursor.subtract(const Duration(days: 1));
    }
  }

  void _ensureDateLoaded(DateTime date) {
    final target = _normalizeDate(date);
    final today = _normalizeDate(DateTime.now());
    if (target.isAfter(today) || target.isBefore(_earliestDate)) return;
    while (_indexOfDate(target) < 0) {
      final before = _entries.length;
      _appendOlderDays(_appendDays);
      if (_entries.length == before) break;
    }
  }

  void _scrollLeftToSelected({bool jump = false}) {
    if (!_leftController.hasClients) return;
    final index = _indexOfDate(_selectedDate);
    if (index < 0) return;
    final target = (index * _dateItemExtent).clamp(
      0.0,
      _leftController.position.maxScrollExtent,
    );
    if (jump) {
      _leftController.jumpTo(target);
    } else {
      _leftController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _jumpToDate(DateTime date) async {
    final normalized = _normalizeDate(date);
    _ensureDateLoaded(normalized);
    if (_indexOfDate(normalized) < 0) return;

    setState(() {
      _selectedDate = normalized;
    });
    _scrollLeftToSelected();
    await _jumpRightToDate(normalized);
  }

  Future<void> _jumpRightToDate(DateTime date, {bool jump = false}) async {
    if (!_rightController.hasClients) return;
    final index = _indexOfDate(date);
    if (index < 0) return;

    final key = _cardKeys[index];
    final ctx = key.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: jump ? Duration.zero : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.02,
      );
    } else {
      final target = (index * _estimatedCardHeight).clamp(
        0.0,
        _rightController.position.maxScrollExtent,
      );
      if (jump) {
        _rightController.jumpTo(target);
      } else {
        await _rightController.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    }

    await _loadEntry(index);
  }

  Future<void> _preloadInitialCards() async {
    final selectedIndex = _indexOfDate(_selectedDate);
    if (selectedIndex >= 0) {
      await _loadEntry(selectedIndex, skipAccessCheck: true);
    }
    for (var i = 0; i < _entries.length && i < 3; i++) {
      if (i != selectedIndex) {
        await _loadEntry(i, cachedOnly: true);
      }
    }
  }

  Future<void> _initializeAi() async {
    try {
      final enabled = await DailyReviewSummaryBuilder.isAiEnabled();
      final consent = await DailyReviewSummaryBuilder.hasAiConsent();
      if (!mounted) return;
      setState(() {
        _aiEnabled = enabled;
        _aiConsent = consent;
        _aiSettingsReady = true;
      });

      if (_aiEnabled && !_aiConsent) {
        await _requestAiConsent();
      }
      if (!mounted) return;
      await _preloadInitialCards();
    } catch (_) {
      // Privacy settings fail closed: no automatic AI request is attempted.
      if (!mounted) return;
      setState(() {
        _aiEnabled = false;
        _aiConsent = false;
        _aiSettingsReady = true;
      });
    }
  }

  Future<bool> _ensureAiAccess() async {
    if (!_aiSettingsReady) {
      try {
        final enabled = await DailyReviewSummaryBuilder.isAiEnabled();
        final consent = await DailyReviewSummaryBuilder.hasAiConsent();
        if (!mounted) return false;
        setState(() {
          _aiEnabled = enabled;
          _aiConsent = consent;
          _aiSettingsReady = true;
        });
      } catch (_) {
        return false;
      }
    }

    if (!_aiEnabled) return false;
    if (_aiConsent) return true;
    return _requestAiConsent();
  }

  Future<bool> _requestAiConsent() async {
    if (!mounted) return false;
    if (_aiConsentDialogShowing) return false;
    _aiConsentDialogShowing = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('使用 AI 复盘前请确认'),
          content: const Text(
            '复盘会将当天及前一天的时间记录（事项名称、时长和时间段）发送给 AI 服务，用于生成复盘文字。\n\n'
            '不会发送 API 密钥、照片或精确定位。你可以随时在右上角 AI 设置中关闭功能或清理本地缓存。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('暂不使用'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('同意并开启'),
            ),
          ],
        ),
      );

      if (!mounted) return false;
      if (accepted == true) {
        final consentSaved = await DailyReviewSummaryBuilder.recordAiConsent();
        final enabledSaved = await DailyReviewSummaryBuilder.setAiEnabled(true);
        if (!mounted) return false;
        setState(() {
          _aiConsent = consentSaved;
          _aiEnabled = enabledSaved;
          _aiSettingsReady = true;
        });
        return consentSaved && enabledSaved;
      }

      await DailyReviewSummaryBuilder.setAiEnabled(false);
      if (!mounted) return false;
      setState(() {
        _aiEnabled = false;
        _aiSettingsReady = true;
      });
      return false;
    } finally {
      _aiConsentDialogShowing = false;
    }
  }

  Future<void> _loadEntry(
    int index, {
    bool cachedOnly = false,
    bool skipAccessCheck = false,
  }) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    if (entry.loading) return;
    if (entry.result != null && entry.result!.isSuccess) return;

    if (!cachedOnly) {
      final allowed =
          skipAccessCheck ? _aiEnabled && _aiConsent : await _ensureAiAccess();
      if (!allowed) {
        if (!mounted) return;
        setState(() {
          entry.result = DailyReviewAiResult(
            date: entry.date,
            title: '${entry.date.month}月${entry.date.day}日 · 今日复盘',
            error: _aiEnabled
                ? DailyReviewAiError.consentRequired
                : DailyReviewAiError.aiDisabled,
          );
          entry.loading = false;
        });
        return;
      }
    }

    setState(() {
      entry.loading = true;
    });

    DailyReviewAiResult? result;
    if (!cachedOnly) {
      result = await DailyReviewSummaryBuilder.loadCachedAi(entry.date);
    }
    if (!cachedOnly && result == null) {
      result = await DailyReviewSummaryBuilder.fetchAiForDate(entry.date);
    }

    if (!mounted) return;
    setState(() {
      entry.result = result;
      entry.loading = false;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: _earliestDate,
      lastDate: DateTime.now(),
      locale: const Locale('zh', 'CN'),
    );
    if (picked == null) return;

    await _jumpToDate(picked);
  }

  void _onRightScroll() {
    if (!_rightController.hasClients || _entries.isEmpty) return;

    final offset = _rightController.offset;
    final approxIndex = (offset / _estimatedCardHeight).round();
    if (approxIndex >= 0 && approxIndex < _entries.length) {
      final date = _entries[approxIndex].date;
      if (!_sameDate(date, _selectedDate)) {
        setState(() {
          _selectedDate = date;
        });
        _scrollLeftToSelected();
      }
      _loadEntry(approxIndex, cachedOnly: true);
    }

    final nearBottom = offset >=
        (_rightController.position.maxScrollExtent - _estimatedCardHeight);
    if (nearBottom) {
      _loadMoreDates();
    }
  }

  Future<void> _loadMoreDates() async {
    if (_loadingMore || _entries.isEmpty) return;
    if (_entries.last.date.isBefore(_earliestDate) ||
        _sameDate(_entries.last.date, _earliestDate)) {
      return;
    }
    setState(() => _loadingMore = true);
    final before = _entries.length;
    _appendOlderDays(_appendDays);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
    });
    if (_entries.length > before) {
      final start = before;
      final end = (_entries.length).clamp(before, before + 3);
      for (var i = start; i < end; i++) {
        _loadEntry(i, cachedOnly: true);
      }
    }
  }

  String _weekdayLabel(DateTime date) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${names[date.weekday - 1]}';
  }

  Widget _buildDateRail() {
    final today = _normalizeDate(DateTime.now());
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 90,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        border: Border(
          right: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: ListView.builder(
        controller: _leftController,
        itemExtent: _dateItemExtent,
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final date = _entries[index].date;
          final selected = _sameDate(date, _selectedDate);
          final isToday = _sameDate(date, today);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Material(
              color:
                  selected ? colorScheme.primaryContainer : Colors.transparent,
              borderRadius: AppRadius.controlAll,
              child: InkWell(
                borderRadius: AppRadius.controlAll,
                onTap: () => _jumpToDate(date),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${date.month}/${date.day}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isToday ? '今天' : _weekdayLabel(date),
                      style: TextStyle(
                        fontSize: 11,
                        color: selected
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(
          '每日复盘',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        actions: [
          IconButton(
            tooltip: 'AI 设置',
            onPressed: _showAiSettings,
            icon: const Icon(Icons.auto_awesome_outlined),
          ),
          IconButton(
            tooltip: '选择日期',
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
        ],
      ),
      body: Row(
        children: [
          _buildDateRail(),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                _onRightScroll();
                return false;
              },
              child: _buildWaterfall(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaterfall() {
    return ListView(
      controller: _rightController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        for (var i = 0; i < _entries.length; i++) ...[
          _buildCard(i),
          const SizedBox(height: 12),
        ],
        if (_loadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCard(int index) {
    final entry = _entries[index];
    final result = entry.result;
    final selected = _sameDate(entry.date, _selectedDate);
    final title = '${entry.date.month}月${entry.date.day}日 · 今日复盘';
    final colorScheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;

    return Container(
      key: _cardKeys[index],
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: AppRadius.cardAll,
        border: selected
            ? Border.all(color: colorScheme.primary, width: 1.2)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black
                .withValues(alpha: brightness == Brightness.dark ? 0.16 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 10),
          if (entry.loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (result == null)
            _buildCardAction(
              label: '生成当日复盘',
              onTap: () => _loadEntry(index),
            )
          else if (!result.isSuccess)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.errorMessage,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                _buildCardAction(
                  label: result.error == DailyReviewAiError.aiDisabled
                      ? '打开 AI 设置'
                      : '重试',
                  onTap: result.error == DailyReviewAiError.aiDisabled
                      ? _showAiSettings
                      : () => _loadEntry(index),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: AppRadius.sheetAll,
                      ),
                      child: Text(
                        'AI 生成',
                        style: TextStyle(
                          color: colorScheme.onPrimaryContainer,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (result.fromCache) ...[
                      const SizedBox(width: 8),
                      Text(
                        '缓存',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  result.body!,
                  style: const TextStyle(
                    fontSize: 15.5,
                    height: 1.7,
                  ),
                ),
                const SizedBox(height: 14),
                _buildChatSection(entry),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildChatSection(_ReviewEntry entry) {
    const chips = [
      '今天时间花在哪了？',
      '和昨天比怎么样？',
      '有什么建议？',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: chips
              .map(
                (text) => ActionChip(
                  label: Text(text, style: const TextStyle(fontSize: 12)),
                  onPressed: () => DailyReviewChatSheet.open(
                    context,
                    date: entry.date,
                    reviewBody: entry.result?.body,
                    initialQuestion: text,
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => DailyReviewChatSheet.open(
              context,
              date: entry.date,
              reviewBody: entry.result?.body,
            ),
            icon: const Icon(Icons.chat_bubble_outline, size: 18),
            label: const Text('继续问 AI'),
          ),
        ),
      ],
    );
  }

  Widget _buildCardAction({
    required String label,
    required VoidCallback onTap,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.auto_awesome, size: 18),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Future<void> _showAiSettings() async {
    if (!_aiSettingsReady) await _ensureAiAccess();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, updateSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      title: const Text('启用 AI 复盘'),
                      subtitle: Text(
                        _aiConsent ? '已同意数据使用说明' : '首次使用前需要确认数据用途',
                      ),
                      value: _aiEnabled,
                      onChanged: (value) async {
                        if (!value) {
                          await DailyReviewSummaryBuilder.setAiEnabled(false);
                          if (!mounted) return;
                          setState(() {
                            _aiEnabled = false;
                            for (final entry in _entries) {
                              entry.result = null;
                            }
                          });
                        } else {
                          await _requestAiConsentIfNeeded();
                        }
                        if (sheetContext.mounted) updateSheet(() {});
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_sweep_outlined),
                      title: const Text('清理 AI 缓存'),
                      subtitle: const Text('删除当前身份保存的复盘结果缓存'),
                      onTap: () async {
                        await DailyReviewSummaryBuilder.clearAiCache();
                        if (!mounted) return;
                        setState(() {
                          for (final entry in _entries) {
                            entry.result = null;
                          }
                        });
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                        messenger.showSnackBar(
                          const SnackBar(content: Text('AI 缓存已清理')),
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _requestAiConsentIfNeeded() async {
    if (_aiConsent) {
      await DailyReviewSummaryBuilder.setAiEnabled(true);
      if (!mounted) return;
      setState(() => _aiEnabled = true);
      return;
    }
    await _requestAiConsent();
  }
}

class _ReviewEntry {
  final DateTime date;
  DailyReviewAiResult? result;
  bool loading;

  _ReviewEntry({required this.date})
      : result = null,
        loading = false;
}
