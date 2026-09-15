import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/category.dart';
import '../models/check_in_document.dart';
import '../models/check_in_goal.dart';
import '../models/daily_review_chat_message.dart';
import '../models/diary_kind.dart';
import '../models/global_search_result.dart';
import '../models/known_google_users.dart';
import '../models/target.dart';
import '../models/time_slot.dart';
import '../models/travel_record.dart';
import '../providers/time_provider.dart';
import 'app_identity_service.dart';
import 'check_in_local_store.dart';
import 'daily_review_chat_store.dart';
import 'daily_review_summary.dart';
import 'diary_search_service.dart';
import 'travel_local_store.dart';

/// 仅从当前设备已有的本地数据建立统一搜索索引。
///
/// 这个服务不会调用任何 remote service，也不会为了搜索触发同步。日记只使用
/// 已有的内存/磁盘索引与草稿；出行、打卡只读取本地草稿。AI 复盘只读取
/// 当前身份下由其存储服务暴露的、受 TTL 和数量限制的本地缓存，不会触发
/// 网络请求，也不会扫描未知路径或直接耦合未公开的存储键。
class UnifiedSearchService {
  static const String _recentSearchesKey = 'global_search_recent_v1';
  static const int maxRecentSearches = 8;
  static const int maxSourceResults = 1000;
  static const int maxAiSearchResults = 120;
  static const int _maxDiaryDraftLength = 16000;

  final TimeProvider? _timeProvider;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final Future<TravelRecordsDocument?> Function() _travelLoader;
  final Future<CheckInDocument?> Function() _checkInLoader;
  GlobalSearchIndex? _index;
  Future<GlobalSearchIndex>? _indexLoading;

  UnifiedSearchService({
    TimeProvider? timeProvider,
    Future<SharedPreferences> Function()? preferencesLoader,
    Future<TravelRecordsDocument?> Function()? travelLoader,
    Future<CheckInDocument?> Function()? checkInLoader,
  })  : _timeProvider = timeProvider,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _travelLoader = travelLoader ?? _loadTravelDraft,
        _checkInLoader = checkInLoader ?? _loadCheckInDraft;

  /// 给 widget 测试和纯本地场景使用的固定索引构造器。
  factory UnifiedSearchService.fromIndex(GlobalSearchIndex index) {
    return UnifiedSearchService._fromIndex(index);
  }

  UnifiedSearchService._fromIndex(GlobalSearchIndex index)
      : _timeProvider = null,
        _preferencesLoader = SharedPreferences.getInstance,
        _travelLoader = _loadTravelDraft,
        _checkInLoader = _loadCheckInDraft,
        _index = index;

  Future<GlobalSearchIndex> loadLocalIndex() {
    final cached = _index;
    if (cached != null) return Future.value(cached);
    final loading = _indexLoading;
    if (loading != null) return loading;

    final future = _buildLocalIndex();
    _indexLoading = future;
    return future.whenComplete(() {
      if (identical(_indexLoading, future)) _indexLoading = null;
    });
  }

  Future<List<GlobalSearchResult>> search(
    String query, {
    GlobalSearchContentType contentType = GlobalSearchContentType.all,
    GlobalSearchIdentityFilter identity = GlobalSearchIdentityFilter.all,
    DateTime? startDate,
    DateTime? endDate,
    int limit = GlobalSearchIndex.maxResults,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];

    final index = await loadLocalIndex();
    // DiarySearchService 的缓存对外只提供“按关键词搜索”，因此把它作为
    // 查询期的一个本地动态数据源；不会因未加载而拿 token 触发远程同步。
    final diaryResults = _searchLoadedDiaries(normalized);
    final diaryKeys = diaryResults
        .map((result) =>
            '${result.identityKind?.code}:${_dateKey(result.date!)}')
        .toSet();
    final draftResults = await _searchDiaryDrafts(
      normalized,
      excludedKeys: diaryKeys,
    );
    final merged = GlobalSearchIndex([
      ...index.entries,
      ...diaryResults,
      ...draftResults,
    ]);
    return merged.search(
      normalized,
      contentType: contentType,
      identity: identity,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    );
  }

  Future<List<String>> loadRecentSearches() async {
    await AppIdentityService.load();
    final prefs = await _preferencesLoader();
    final values = prefs.getStringList(
          AppIdentityService.dataKeyForCurrentIdentity(_recentSearchesKey),
        ) ??
        const <String>[];
    return List.unmodifiable(
      values
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .take(maxRecentSearches),
    );
  }

  Future<void> rememberSearch(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return;
    await AppIdentityService.load();
    final prefs = await _preferencesLoader();
    final key =
        AppIdentityService.dataKeyForCurrentIdentity(_recentSearchesKey);
    final existing = prefs.getStringList(key) ?? const <String>[];
    final next = <String>[normalized, ...existing]
        .where((value) => value.trim().isNotEmpty)
        .fold<List<String>>([], (result, value) {
      if (!result.any((item) => item.toLowerCase() == value.toLowerCase())) {
        result.add(value.trim());
      }
      return result;
    });
    await prefs.setStringList(key, next.take(maxRecentSearches).toList());
  }

  Future<void> clearRecentSearches() async {
    await AppIdentityService.load();
    final prefs = await _preferencesLoader();
    await prefs.remove(
      AppIdentityService.dataKeyForCurrentIdentity(_recentSearchesKey),
    );
  }

  Future<GlobalSearchIndex> _buildLocalIndex() async {
    await AppIdentityService.load();
    final prefs = await _preferencesLoader();
    final entries = <GlobalSearchResult>[];
    _addAiReviewEntries(entries, await _loadAiReviewEntries());
    final provider = _timeProvider;
    if (provider != null) {
      _addScheduleEntries(entries, prefs, provider);
    }

    final travel = await _travelLoader();
    if (travel != null) _addTravelEntries(entries, travel);

    final checkIn = await _checkInLoader();
    if (checkIn != null) _addCheckInEntries(entries, checkIn);

    return _index = GlobalSearchIndex(entries);
  }

  Future<List<_AiSearchEntry>> _loadAiReviewEntries() async {
    final entries = <_AiSearchEntry>[];
    try {
      final summaries = await DailyReviewSummaryBuilder.loadCachedForSearch();
      for (final summary in summaries) {
        entries.add(_AiSearchEntry.summary(summary));
      }
    } catch (_) {
      // AI cache is optional; a failure must not hide other local modules.
    }

    try {
      final sessions = await DailyReviewChatStore.loadSessionsForSearch();
      for (final session in sessions) {
        for (final message in session.session.messages) {
          if (message.content.trim().isEmpty) continue;
          entries.add(_AiSearchEntry.message(session.date, message));
          if (entries.length >= maxAiSearchResults) {
            return entries;
          }
        }
      }
    } catch (_) {
      // A corrupt or unavailable chat cache must not block ordinary search.
    }
    return entries;
  }

  void _addAiReviewEntries(
    List<GlobalSearchResult> entries,
    List<_AiSearchEntry> aiEntries,
  ) {
    final identityKind = AppIdentityService.personKind;
    for (final entry in aiEntries.take(maxAiSearchResults)) {
      if (entry.summary != null) {
        final body = _limitText(
          entry.summary!.body,
          DailyReviewSummaryBuilder.maxSearchBodyLength,
        );
        entries.add(
          GlobalSearchResult(
            type: GlobalSearchContentType.aiReview,
            date: entry.summary!.date,
            title: '每日复盘摘要',
            summary: _limitText(_oneLine(body), 240),
            details: body,
            identityKind: identityKind,
            entityId: 'summary:${_dateKey(entry.summary!.date)}',
          ),
        );
        continue;
      }

      final message = entry.message!;
      final content = _limitText(
        message.content,
        DailyReviewChatStore.maxSearchMessageContentLength,
      );
      final roleLabel = message.isUser ? '提问' : '回答';
      entries.add(
        GlobalSearchResult(
          type: GlobalSearchContentType.aiReview,
          date: entry.date,
          title: '复盘对话 · $roleLabel',
          summary: '$roleLabel：${_limitText(_oneLine(content), 240)}',
          details: content,
          identityKind: identityKind,
          entityId: 'chat:${_dateKey(entry.date!)}:${message.createdAt}',
        ),
      );
    }
  }

  void _addScheduleEntries(
    List<GlobalSearchResult> entries,
    SharedPreferences prefs,
    TimeProvider provider,
  ) {
    final currentKind = AppIdentityService.personKind ?? provider.scheduleUser;
    final namespaced = !provider.isWindows;
    final kinds = namespaced
        ? const <DiaryKind>[DiaryKind.g, DiaryKind.j]
        : <DiaryKind>[currentKind];

    for (final kind in kinds) {
      final isLiveCurrent =
          kind == currentKind && provider.isInitialLoadFinished;
      final categories = isLiveCurrent
          ? provider.categories
          : _readCategories(prefs, kind, namespaced: namespaced);
      final targets = isLiveCurrent
          ? provider.targets
          : _readTargets(prefs, kind, namespaced: namespaced);
      final slots = _readSlots(prefs, kind, provider, namespaced: namespaced);
      _addCategoryEntries(entries, categories, kind);
      _addTargetEntries(entries, targets, categories, kind);
      _addTimeRecordEntries(entries, slots, categories, kind);
    }
  }

  List<Category> _readCategories(
    SharedPreferences prefs,
    DiaryKind kind, {
    required bool namespaced,
  }) {
    final key = _dataKey('categories', kind, namespaced: namespaced);
    final values = prefs.getStringList(key) ?? const <String>[];
    final result = <Category>[];
    for (final value in values.take(maxSourceResults)) {
      try {
        final decoded = json.decode(value);
        if (decoded is Map) {
          result.add(Category.fromJson(Map<String, dynamic>.from(decoded)));
        }
      } catch (_) {
        // 一条坏的本地记录不应阻断其它模块搜索。
      }
    }
    return result;
  }

  List<Target> _readTargets(
    SharedPreferences prefs,
    DiaryKind kind, {
    required bool namespaced,
  }) {
    final key = _dataKey('targets', kind, namespaced: namespaced);
    final values = prefs.getStringList(key) ?? const <String>[];
    final result = <Target>[];
    for (final value in values.take(maxSourceResults)) {
      try {
        final decoded = json.decode(value);
        if (decoded is Map) {
          result.add(Target.fromJson(Map<String, dynamic>.from(decoded)));
        }
      } catch (_) {
        // 一条坏的本地记录不应阻断其它模块搜索。
      }
    }
    return result;
  }

  Map<String, List<TimeSlot>> _readSlots(
    SharedPreferences prefs,
    DiaryKind kind,
    TimeProvider provider, {
    required bool namespaced,
  }) {
    final key = _dataKey('daily_slots', kind, namespaced: namespaced);
    final raw = prefs.getString(key);
    final result = <String, List<TimeSlot>>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries.take(maxSourceResults)) {
            final dateKey = _canonicalDateKey(entry.key.toString());
            final items = entry.value;
            if (dateKey == null || items is! List) continue;
            final slots = <TimeSlot>[];
            for (final item in items.take(144)) {
              if (item is! Map) continue;
              final map = Map<String, dynamic>.from(item);
              final index = _asInt(map['i']);
              final label = map['l']?.toString();
              if (index < 0 || index >= 144 || label == null || label.isEmpty) {
                continue;
              }
              slots.add(
                TimeSlot(
                  hour: index ~/ 6,
                  minute10: index % 6,
                  recorded: true,
                  label: label,
                  categoryId: map['cid']?.toString(),
                  isFromCalendar: map['fc'] == true,
                ),
              );
            }
            if (slots.isNotEmpty) result[dateKey] = slots;
          }
        }
      } catch (_) {
        // 保留可解析的其它本地模块。
      }
    }

    // 当前日尚未落盘的编辑仍可通过 Provider 的公开日期读取 API 被搜索到；
    // 不遍历未知日期，也不会为搜索生成或同步远程数据。
    final currentKind = AppIdentityService.personKind ?? provider.scheduleUser;
    if (provider.isInitialLoadFinished && kind == currentKind) {
      final currentDate = provider.currentDate;
      final liveSlots = (provider.getSlotsForDate(_dateKey(currentDate)) ??
              const [])
          .where((slot) => slot.recorded && (slot.label?.isNotEmpty ?? false))
          .toList();
      if (liveSlots.isNotEmpty) {
        result[_dateKey(currentDate)] = liveSlots;
      }
    }
    return result;
  }

  void _addCategoryEntries(
    List<GlobalSearchResult> entries,
    List<Category> categories,
    DiaryKind kind,
  ) {
    for (final category in categories.take(maxSourceResults)) {
      final subCategories = category.subCategories
          .where((value) => value.trim().isNotEmpty)
          .toList();
      final suffix =
          subCategories.isEmpty ? '分类' : '分类 · 子分类：${subCategories.join('、')}';
      entries.add(
        GlobalSearchResult(
          type: GlobalSearchContentType.category,
          date: _dateFromMillis(category.updatedAt),
          title: category.name,
          summary: suffix,
          identityKind: kind,
          entityId: category.id,
        ),
      );
    }
  }

  void _addTargetEntries(
    List<GlobalSearchResult> entries,
    List<Target> targets,
    List<Category> categories,
    DiaryKind kind,
  ) {
    final categoriesById = <String, String>{
      for (final category in categories) category.id: category.name,
    };
    for (final target in targets.take(maxSourceResults)) {
      final typeLabel = switch (target.type) {
        TargetType.duration => '时长目标 ${target.durationHours} 小时',
        TargetType.timePoint => '时间点目标 ${target.targetTime}',
        TargetType.frequency => '频次目标 ${target.frequencyCount} 次',
      };
      final category = categoriesById[target.categoryId];
      final summary = [
        typeLabel,
        if (target.period.isNotEmpty) target.period,
        if (category != null && category.isNotEmpty) '分类：$category',
      ].join(' · ');
      entries.add(
        GlobalSearchResult(
          type: GlobalSearchContentType.target,
          date: _dateFromMillis(target.updatedAt),
          title: target.name,
          summary: summary,
          identityKind: kind,
          entityId: target.id,
        ),
      );
    }
  }

  void _addTimeRecordEntries(
    List<GlobalSearchResult> entries,
    Map<String, List<TimeSlot>> slotsByDate,
    List<Category> categories,
    DiaryKind kind,
  ) {
    final categoriesById = <String, Category>{
      for (final category in categories) category.id: category,
    };
    final dateKeys = slotsByDate.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final dateKey in dateKeys.take(maxSourceResults)) {
      final slots = slotsByDate[dateKey];
      if (slots == null || slots.isEmpty) continue;
      final sorted = [...slots]..sort(_compareSlot);
      var i = 0;
      while (i < sorted.length) {
        final slot = sorted[i];
        final label = slot.label;
        if (!slot.recorded || label == null || label.isEmpty) {
          i++;
          continue;
        }
        final categoryId = slot.categoryId;
        final start = i;
        i = start + 1;
        while (i < sorted.length &&
            sorted[i].recorded &&
            sorted[i].label == label &&
            sorted[i].categoryId == categoryId &&
            _slotIndex(sorted[i]) == _slotIndex(sorted[i - 1]) + 1) {
          i++;
        }
        final end = i - 1;
        final category = categoriesById[categoryId];
        final range =
            '${_slotTime(sorted[start])}-${_slotEndTime(sorted[end])}';
        final duration = (end - start + 1) * 10;
        final summary = [
          range,
          _formatDuration(duration),
          if (category != null && category.name.isNotEmpty)
            '分类：${category.name}',
        ].join(' · ');
        final date = DateTime.tryParse(dateKey);
        if (date != null) {
          entries.add(
            GlobalSearchResult(
              type: GlobalSearchContentType.timeRecord,
              date: date,
              title: label,
              summary: summary,
              identityKind: kind,
            ),
          );
        }
      }
    }
  }

  void _addTravelEntries(
    List<GlobalSearchResult> entries,
    TravelRecordsDocument document,
  ) {
    for (final record in document.records.take(maxSourceResults)) {
      final summary = [
        if (record.location.trim().isNotEmpty) '地点：${record.location.trim()}',
        if (record.event.trim().isNotEmpty) '事件：${record.event.trim()}',
      ].join(' · ');
      entries.add(
        GlobalSearchResult(
          type: GlobalSearchContentType.travel,
          date: record.date,
          title: record.location.trim().isEmpty ? '出行记录' : record.location,
          summary: summary.isEmpty ? '暂无地点或事件描述' : summary,
          details: [record.location, record.event]
              .where((value) => value.trim().isNotEmpty)
              .join('\n'),
        ),
      );
    }
  }

  void _addCheckInEntries(
    List<GlobalSearchResult> entries,
    CheckInDocument document,
  ) {
    final goalsById = <String, CheckInGoal>{
      for (final goal in document.goals) goal.id: goal,
    };
    for (final goal in document.goals.take(maxSourceResults)) {
      final kind = _kindForUser(goal.ownerId, goal.ownerEmail);
      final summary = [
        if (goal.description.trim().isNotEmpty) goal.description.trim(),
        goal.period.label,
        '目标 ${goal.targetCount} 次',
      ].join(' · ');
      entries.add(
        GlobalSearchResult(
          type: GlobalSearchContentType.checkIn,
          date: _dateFromMillis(goal.updatedAt),
          title: goal.name,
          summary: summary,
          details: goal.description,
          identityKind: kind,
          entityId: goal.id,
        ),
      );
    }

    for (final record in document.records.take(maxSourceResults)) {
      final goal = goalsById[record.goalId];
      final location = record.locationName?.trim() ?? '';
      final note = record.note?.trim() ?? '';
      final summary = [
        if (goal != null && goal.name.trim().isNotEmpty) '目标：${goal.name}',
        if (location.isNotEmpty) '地点：$location',
        if (note.isNotEmpty) '备注：$note',
      ].join(' · ');
      entries.add(
        GlobalSearchResult(
          type: GlobalSearchContentType.checkIn,
          date: record.timestamp,
          title: goal?.name.isNotEmpty == true ? goal!.name : '打卡记录',
          summary: summary.isEmpty ? '打卡记录' : summary,
          details: [
            if (location.isNotEmpty) '地点：$location',
            if (note.isNotEmpty) '备注：$note',
          ].join('\n'),
          identityKind: _kindForUser(record.userId, record.userEmail),
          entityId: record.id,
        ),
      );
    }
  }

  List<GlobalSearchResult> _searchLoadedDiaries(String query) {
    if (!DiarySearchService.isLoaded) return const [];
    final results = DiarySearchService.search(query);
    final entries = <GlobalSearchResult>[];
    for (final result in results.take(maxSourceResults)) {
      final date = result.date;
      final content = DiarySearchService.getCachedContent(result.kind, date);
      entries.add(
        GlobalSearchResult(
          type: GlobalSearchContentType.diary,
          date: date,
          title: result.kind == 'g' ? '乖乖日记' : '晶晶日记',
          summary: result.snippet,
          details: content == null
              ? result.snippet
              : _limitText(content, _maxDiaryDraftLength),
          identityKind: DiaryKindX.fromCode(result.kind),
        ),
      );
    }
    return entries;
  }

  Future<List<GlobalSearchResult>> _searchDiaryDrafts(
    String query, {
    Set<String> excludedKeys = const {},
  }) async {
    final prefs = await _preferencesLoader();
    final lowerQuery = query.toLowerCase();
    final entries = <GlobalSearchResult>[];
    final pattern = RegExp(r'^diary_draft_([gj])_(\d{8})$');
    for (final key in prefs.getKeys()) {
      final match = pattern.firstMatch(key);
      if (match == null) continue;
      final body = prefs.getString(key);
      if (body == null ||
          body.trim().isEmpty ||
          !body.toLowerCase().contains(lowerQuery)) {
        continue;
      }
      final date = _parseCompactDate(match.group(2)!);
      if (date == null) continue;
      final kind = DiaryKindX.fromCode(match.group(1));
      final resultKey = '${kind.code}:${_dateKey(date)}';
      if (excludedKeys.contains(resultKey)) continue;
      entries.add(
        GlobalSearchResult(
          type: GlobalSearchContentType.diary,
          date: date,
          title: kind == DiaryKind.g ? '乖乖日记草稿' : '晶晶日记草稿',
          summary: _extractSnippet(body, lowerQuery),
          details: _limitText(body, _maxDiaryDraftLength),
          identityKind: kind,
        ),
      );
      if (entries.length >= maxSourceResults) break;
    }
    return entries;
  }

  static Future<TravelRecordsDocument?> _loadTravelDraft() async {
    final raw = await TravelLocalStore.loadDraft();
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return TravelRecordsDocument.fromMarkdown(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<CheckInDocument?> _loadCheckInDraft() async {
    return CheckInLocalStore.loadDraft();
  }

  static String _dataKey(
    String base,
    DiaryKind kind, {
    required bool namespaced,
  }) {
    return namespaced ? AppIdentityResolver.dataKey(kind, base) : base;
  }

  static String? _canonicalDateKey(String value) {
    final parsed = DateTime.tryParse(value);
    return parsed == null ? null : _dateKey(parsed);
  }

  static String _dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  static DateTime? _dateFromMillis(int value) {
    if (value <= 0) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(value);
    final now = DateTime.now();
    if (date.isAfter(now.add(const Duration(days: 365)))) return null;
    return DateTime(date.year, date.month, date.day);
  }

  static int _asInt(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? -1;
  }

  static int _slotIndex(TimeSlot slot) => slot.hour * 6 + slot.minute10;

  static int _compareSlot(TimeSlot a, TimeSlot b) =>
      _slotIndex(a).compareTo(_slotIndex(b));

  static String _slotTime(TimeSlot slot) =>
      '${slot.hour.toString().padLeft(2, '0')}:${(slot.minute10 * 10).toString().padLeft(2, '0')}';

  static String _slotEndTime(TimeSlot slot) {
    final index = (_slotIndex(slot) + 1).clamp(0, 144);
    return '${(index ~/ 6).toString().padLeft(2, '0')}:${((index % 6) * 10).toString().padLeft(2, '0')}';
  }

  static String _formatDuration(int minutes) {
    if (minutes < 60) return '$minutes分钟';
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    return remainder == 0 ? '$hours小时' : '$hours小时$remainder分钟';
  }

  static String _limitText(String value, int limit) {
    if (value.length <= limit) return value;
    return '${value.substring(0, limit)}…';
  }

  static String _oneLine(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _extractSnippet(String content, String lowerQuery) {
    final lower = content.toLowerCase();
    final index = lower.indexOf(lowerQuery);
    if (index < 0) return _oneLine(content);
    const radius = 50;
    final start = (index - radius).clamp(0, content.length);
    final end = (index + lowerQuery.length + radius).clamp(0, content.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < content.length ? '…' : '';
    return '$prefix${_oneLine(content.substring(start, end))}$suffix';
  }

  static DateTime? _parseCompactDate(String value) {
    if (value.length != 8) return null;
    final year = int.tryParse(value.substring(0, 4));
    final month = int.tryParse(value.substring(4, 6));
    final day = int.tryParse(value.substring(6));
    if (year == null || month == null || day == null) return null;
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  static DiaryKind? _kindForUser(String id, String email) {
    final nickname = KnownGoogleUsers.nicknameFor(email);
    if (nickname == '乖乖' || id == 'manual-g') return DiaryKind.g;
    if (nickname == '晶晶' || id == 'manual-j') return DiaryKind.j;
    return null;
  }
}

class _AiSearchEntry {
  final DailyReviewSummarySearchEntry? summary;
  final DateTime? date;
  final DailyReviewChatMessage? message;

  const _AiSearchEntry._({
    this.summary,
    this.date,
    this.message,
  });

  factory _AiSearchEntry.summary(DailyReviewSummarySearchEntry summary) {
    return _AiSearchEntry._(summary: summary);
  }

  factory _AiSearchEntry.message(
    DateTime date,
    DailyReviewChatMessage message,
  ) {
    return _AiSearchEntry._(date: date, message: message);
  }
}
