import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'app_identity_service.dart';
import 'siliconflow_ai_service.dart';

enum DailyReviewAiError {
  noApiKey,
  aiDisabled,
  consentRequired,
  networkFailed,
  timeout,
}

class DailyReviewAiResult {
  final DateTime date;
  final String title;
  final String? body;
  final bool fromCache;
  final DailyReviewAiError? error;

  const DailyReviewAiResult({
    required this.date,
    required this.title,
    this.body,
    this.fromCache = false,
    this.error,
  });

  bool get isSuccess => body != null && body!.isNotEmpty;

  String get errorMessage {
    switch (error) {
      case DailyReviewAiError.noApiKey:
        return '未配置 AI API Key，请在 lib/config/siliconflow_config.dart 中填写。';
      case DailyReviewAiError.aiDisabled:
        return 'AI 复盘已关闭，请在右上角 AI 设置中开启。';
      case DailyReviewAiError.consentRequired:
        return '首次使用 AI 前需要先阅读并同意数据使用说明。';
      case DailyReviewAiError.networkFailed:
        return 'AI 生成失败，请检查网络后重试。';
      case DailyReviewAiError.timeout:
        return 'AI 响应超时，请检查网络后重试。';
      case null:
        return '未知错误';
    }
  }
}

/// A bounded local-only entry exposed to the unified search index.
///
/// This type deliberately contains only an already persisted final answer. It
/// never represents a prompt, token, request, or remote response metadata.
class DailyReviewSummarySearchEntry {
  final DateTime date;
  final String body;
  final DateTime createdAt;

  const DailyReviewSummarySearchEntry({
    required this.date,
    required this.body,
    required this.createdAt,
  });
}

class DailyReviewSummaryBuilder {
  static const _cachePrefix = 'daily_review_ai_cache_';
  static const cacheRetention = Duration(days: 30);
  static const payloadPrefix = 'daily_review:';
  static const maxSearchEntries = 60;
  static const maxSearchBodyLength = 16000;

  static Future<bool> isAiEnabled() => AiPrivacySettings.isEnabled();

  static Future<bool> hasAiConsent() => AiPrivacySettings.hasConsent();

  static Future<bool> setAiEnabled(bool enabled) {
    return AiPrivacySettings.setEnabled(enabled);
  }

  static Future<bool> recordAiConsent() {
    return AiPrivacySettings.recordConsent();
  }

  static String payloadForDate(DateTime date) =>
      '$payloadPrefix${dateKey(date)}';

  static DateTime? dateFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(payloadPrefix)) return null;
    final key = payload.substring(payloadPrefix.length);
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  static Future<void> clearAiCache() async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    final cachePrefix = AppIdentityService.dataKeyForCurrentIdentity(
      _cachePrefix,
    );
    for (final key in prefs.getKeys()) {
      if (key.startsWith(cachePrefix)) {
        await prefs.remove(key);
      }
    }
  }

  static String dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  static Future<DailyReviewAiResult?> loadCachedAi(DateTime date) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    final slotsKey =
        AppIdentityService.dataKeyForCurrentIdentity('daily_slots');
    final dataHash = _hashDayData(prefs, date, slotsKey: slotsKey);
    final body = await _loadCachedAiBody(
      prefs: prefs,
      dataHash: dataHash,
      cacheKey: AppIdentityService.dataKeyForCurrentIdentity(
        '$_cachePrefix${dateKey(date)}',
      ),
      cacheDate: date,
    );
    if (body == null) return null;
    return DailyReviewAiResult(
      date: date,
      title: _titleForDate(date),
      body: body,
      fromCache: true,
    );
  }

  /// Enumerates only the current identity's known, date-keyed summary cache.
  ///
  /// This is intentionally separate from generation: it performs no network
  /// request and does not change consent or enabled settings. Expiration and
  /// the existing day-data hash check are retained so stale or malformed
  /// cache entries never enter local search. A caller cannot raise the number
  /// of entries or the size of an individual body beyond these limits.
  static Future<List<DailyReviewSummarySearchEntry>> loadCachedForSearch({
    int limit = maxSearchEntries,
    DateTime? now,
  }) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    final safeLimit = limit.clamp(1, maxSearchEntries);
    final prefix = AppIdentityService.dataKeyForCurrentIdentity(_cachePrefix);
    final slotsKey =
        AppIdentityService.dataKeyForCurrentIdentity('daily_slots');
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(cacheRetention);
    final candidates = <DailyReviewSummarySearchEntry>[];

    // Only inspect keys under the exact current-identity cache prefix. No
    // filesystem paths or arbitrary SharedPreferences values are scanned.
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(prefix)) continue;
      final date = _dateFromCacheKey(key, prefix);
      if (date == null) continue;

      try {
        final raw = prefs.getString(key);
        final cached = _decodeCachedAi(raw);
        if (cached == null) continue;
        final createdAt = cached.createdAt ?? date;
        if (createdAt.toUtc().isBefore(cutoff)) {
          await prefs.remove(key);
          continue;
        }

        final dataHash = _hashDayData(prefs, date, slotsKey: slotsKey);
        if (cached.hash != dataHash) continue;
        final body = cached.body;
        if (body == null ||
            body.isEmpty ||
            SiliconFlowAiService.looksLikeThinkingProcess(body)) {
          continue;
        }

        candidates.add(
          DailyReviewSummarySearchEntry(
            date: date,
            body: _limitSearchBody(body),
            createdAt: createdAt,
          ),
        );
      } catch (_) {
        // One corrupt cache entry must not block the remaining dates.
      }
    }

    candidates.sort((a, b) {
      final dateCompare = b.date.compareTo(a.date);
      if (dateCompare != 0) return dateCompare;
      return b.createdAt.compareTo(a.createdAt);
    });
    return List.unmodifiable(candidates.take(safeLimit));
  }

  /// 仅 AI 生成复盘（有缓存则直接返回）
  static Future<DailyReviewAiResult> fetchAiForDate(DateTime date) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    final slotsKey =
        AppIdentityService.dataKeyForCurrentIdentity('daily_slots');
    final categoriesKey =
        AppIdentityService.dataKeyForCurrentIdentity('categories');
    final cacheKey = AppIdentityService.dataKeyForCurrentIdentity(
      '$_cachePrefix${dateKey(date)}',
    );
    final title = _titleForDate(date);

    if (!await AiPrivacySettings.isEnabled()) {
      return DailyReviewAiResult(
        date: date,
        title: title,
        error: DailyReviewAiError.aiDisabled,
      );
    }
    if (!await AiPrivacySettings.hasConsent()) {
      return DailyReviewAiResult(
        date: date,
        title: title,
        error: DailyReviewAiError.consentRequired,
      );
    }

    final todayStats = await _loadDayStats(prefs, date, slotsKey: slotsKey);
    final yesterday = date.subtract(const Duration(days: 1));
    final yesterdayStats =
        await _loadDayStats(prefs, yesterday, slotsKey: slotsKey);
    final dataHash = _hashDayData(prefs, date, slotsKey: slotsKey);

    if (!SiliconFlowAiService.hasApiKeyConfigured) {
      return DailyReviewAiResult(
        date: date,
        title: title,
        error: DailyReviewAiError.noApiKey,
      );
    }

    final cached = await _loadCachedAiBody(
      prefs: prefs,
      dataHash: dataHash,
      cacheKey: cacheKey,
      cacheDate: date,
    );
    if (cached != null) {
      return DailyReviewAiResult(
        date: date,
        title: title,
        body: cached,
        fromCache: true,
      );
    }

    final timeline = await _loadDayTimeline(prefs, date, slotsKey: slotsKey);
    final labelToCategory =
        await _loadLabelCategoryMap(prefs, categoriesKey: categoriesKey);
    final highlights = _buildHighlights(timeline, todayStats);

    final prompt = _buildReviewPrompt(
      date: date,
      todayStats: todayStats,
      yesterdayStats: yesterdayStats,
      timeline: timeline,
      highlights: highlights,
      labelToCategory: labelToCategory,
      unrecordedGaps:
          await _loadUnrecordedGaps(prefs, date, slotsKey: slotsKey),
    );

    final result = await SiliconFlowAiService.generateDailyReview(
      userPrompt: prompt,
    );

    if (result.content == null || result.content!.isEmpty) {
      return DailyReviewAiResult(
        date: date,
        title: title,
        error: result.timedOut
            ? DailyReviewAiError.timeout
            : DailyReviewAiError.networkFailed,
      );
    }

    await prefs.setString(
      cacheKey,
      json.encode({
        'hash': dataHash,
        'body': result.content,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );

    return DailyReviewAiResult(
      date: date,
      title: title,
      body: result.content,
      fromCache: false,
    );
  }

  static String _titleForDate(DateTime date) =>
      '${date.month}月${date.day}日 · 今日复盘';

  /// 供对话使用的当日记录（完整时间轴 + 全部事项）
  static Future<String> buildDayContext(DateTime date) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    final slotsKey =
        AppIdentityService.dataKeyForCurrentIdentity('daily_slots');
    final categoriesKey =
        AppIdentityService.dataKeyForCurrentIdentity('categories');
    final todayStats = await _loadDayStats(prefs, date, slotsKey: slotsKey);
    final yesterday = date.subtract(const Duration(days: 1));
    final yesterdayStats =
        await _loadDayStats(prefs, yesterday, slotsKey: slotsKey);
    final timeline = await _loadDayTimeline(prefs, date, slotsKey: slotsKey);
    final labelToCategory =
        await _loadLabelCategoryMap(prefs, categoriesKey: categoriesKey);
    return _buildDayContextString(
      date: date,
      todayStats: todayStats,
      yesterdayStats: yesterdayStats,
      timeline: timeline,
      labelToCategory: labelToCategory,
      unrecordedGaps:
          await _loadUnrecordedGaps(prefs, date, slotsKey: slotsKey),
      fullDetail: true,
    );
  }

  /// 当日时间记录指纹，用于判断对话上下文是否过期
  static Future<String> computeDayDataHash(DateTime date) async {
    await AppIdentityService.load();
    final prefs = await SharedPreferences.getInstance();
    return _hashDayData(
      prefs,
      date,
      slotsKey: AppIdentityService.dataKeyForCurrentIdentity('daily_slots'),
    );
  }

  static String _buildDayContextString({
    required DateTime date,
    required _DayStats todayStats,
    required _DayStats yesterdayStats,
    required List<_TimeBlock> timeline,
    required Map<String, String> labelToCategory,
    required List<String> unrecordedGaps,
    List<String> highlights = const [],
    bool fullDetail = false,
  }) {
    final weekday = _weekdayLabels[date.weekday - 1];
    final buffer = StringBuffer();
    final todayTotal = todayStats.totalMinutes;
    final delta = todayTotal - yesterdayStats.totalMinutes;
    final now = DateTime.now();
    final snapshot =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    buffer.writeln('日期：${date.month}月${date.day}日（$weekday）');

    if (todayTotal == 0) {
      buffer.writeln('当日无时间记录。');
      return buffer.toString();
    }

    if (fullDetail) {
      buffer.writeln('说明：以下为 $snapshot 的最新完整记录；与对话中早前摘要不一致时，必须以本数据为准。');
    }

    buffer.writeln(
        '记录总时长 ${_formatDuration(todayTotal)}，较昨日 ${_formatDeltaMinutes(delta)}');
    buffer.writeln(
        '自主 ${_formatDuration(todayStats.userMinutes)}，日历/会议 ${_formatDuration(todayStats.calendarMinutes)}');

    if (fullDetail) {
      final allLabels = todayStats.topLabels(limit: 100);
      if (allLabels.isNotEmpty) {
        buffer.writeln('全部事项（按时长）：');
        for (final e in allLabels) {
          buffer.writeln('- ${e.key}：${_formatDuration(e.value)}');
        }
      }

      if (timeline.isNotEmpty) {
        buffer.writeln('完整时间轴（按时间顺序，查具体事件必看此表）：');
        for (final block in timeline) {
          buffer.writeln('- ${_formatBlockLine(block)}');
        }
      }
    } else if (highlights.isNotEmpty) {
      buffer.writeln('重点事项：');
      for (final line in highlights) {
        buffer.writeln(line);
      }
    }

    final yesterdayTop = yesterdayStats.topLabels(limit: 2);
    final todayTop = todayStats.topLabels(limit: 2);
    if (yesterdayTop.isNotEmpty || todayTop.isNotEmpty) {
      if (yesterdayTop.isNotEmpty) {
        buffer.write('昨日侧重：');
        buffer.writeln(
          yesterdayTop
              .map((e) => '${e.key}${_formatDuration(e.value, short: true)}')
              .join('、'),
        );
      }
      if (todayTop.isNotEmpty) {
        buffer.write('今日侧重：');
        buffer.writeln(
          todayTop
              .map((e) => '${e.key}${_formatDuration(e.value, short: true)}')
              .join('、'),
        );
      }
    }

    if (unrecordedGaps.isNotEmpty) {
      buffer.writeln('未记录时段：${unrecordedGaps.join('、')}');
    }

    if (labelToCategory.isNotEmpty) {
      final used = todayStats.labelMinutes.keys.toSet();
      final hints = used
          .where((l) => labelToCategory.containsKey(l))
          .map((l) => '$l→${labelToCategory[l]}')
          .toList()
        ..sort();
      if (hints.isNotEmpty) {
        buffer.writeln('分类归属：${hints.join('，')}');
      }
    }

    return buffer.toString().trim();
  }

  static String _formatBlockLine(_TimeBlock block) {
    final tag = block.fromCalendar ? '日历' : '自主';
    final duration = _formatDuration((block.endIndex - block.startIndex) * 10);
    return '${block.range} ${block.label}（$tag，$duration）';
  }

  static Future<String?> _loadCachedAiBody({
    required SharedPreferences prefs,
    required String dataHash,
    required String cacheKey,
    required DateTime cacheDate,
    DateTime? now,
  }) async {
    final cachedRaw = prefs.getString(cacheKey);
    if (cachedRaw == null) return null;
    try {
      final cached = _decodeCachedAi(cachedRaw);
      if (cached == null) return null;
      final cacheTimestamp = cached.createdAt ?? cacheDate;
      final cutoff = (now ?? DateTime.now()).toUtc().subtract(cacheRetention);
      if (cacheTimestamp.toUtc().isBefore(cutoff)) {
        await prefs.remove(cacheKey);
        return null;
      }
      if (cached.hash == dataHash) {
        final body = cached.body;
        if (body != null &&
            body.isNotEmpty &&
            !SiliconFlowAiService.looksLikeThinkingProcess(body)) {
          return body;
        }
      }
    } catch (_) {}
    return null;
  }

  static DateTime? _dateFromCacheKey(String key, String prefix) {
    final value = key.substring(prefix.length);
    final parts = value.split('-');
    if (parts.length != 3 ||
        parts.any((part) => part.isEmpty || !RegExp(r'^\d+$').hasMatch(part))) {
      return null;
    }
    final date = DateTime.tryParse(value);
    if (date == null || dateKey(date) != value) return null;
    return date;
  }

  static _CachedAi? _decodeCachedAi(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final decoded = json.decode(raw);
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    final hash = map['hash']?.toString();
    final body = map['body'] is String ? (map['body'] as String).trim() : null;
    final createdAt = DateTime.tryParse(map['createdAt']?.toString() ?? '');
    if (hash == null || hash.isEmpty || body == null || body.isEmpty) {
      return null;
    }
    return _CachedAi(hash: hash, body: body, createdAt: createdAt);
  }

  static String _limitSearchBody(String body) {
    if (body.length <= maxSearchBodyLength) return body;
    return '${body.substring(0, maxSearchBodyLength - 1)}…';
  }

  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  static String _buildReviewPrompt({
    required DateTime date,
    required _DayStats todayStats,
    required _DayStats yesterdayStats,
    required List<_TimeBlock> timeline,
    required List<String> highlights,
    required Map<String, String> labelToCategory,
    required List<String> unrecordedGaps,
  }) {
    final context = _buildDayContextString(
      date: date,
      todayStats: todayStats,
      yesterdayStats: yesterdayStats,
      timeline: timeline,
      highlights: highlights,
      labelToCategory: labelToCategory,
      unrecordedGaps: unrecordedGaps,
      fullDetail: false,
    );
    if (todayStats.totalMinutes == 0) {
      return '$context\n\n【要求】约 60 字：说明今天没记什么，建议补记。不要编造。';
    }
    return '$context\n\n【要求】120～180 字，2 段。概括今天在做什么，不要逐条念时间轴。';
  }

  /// 按时长取前 3 项，每项附 1～2 个主要时段
  static List<String> _buildHighlights(
    List<_TimeBlock> timeline,
    _DayStats todayStats,
  ) {
    if (todayStats.labelMinutes.isEmpty) return const [];

    final topLabels = todayStats.topLabels(limit: 3).map((e) => e.key).toList();
    final byLabel = <String, List<_TimeBlock>>{};
    for (final block in timeline) {
      if (!topLabels.contains(block.label)) continue;
      byLabel.putIfAbsent(block.label, () => []).add(block);
    }

    final lines = <String>[];
    for (final label in topLabels) {
      final minutes = todayStats.labelMinutes[label] ?? 0;
      final blocks = byLabel[label] ?? [];
      blocks.sort((a, b) =>
          (b.endIndex - b.startIndex).compareTo(a.endIndex - a.startIndex));
      final ranges = blocks.take(2).map((b) => b.range).join('、');
      final rangeText = ranges.isEmpty ? '' : '，时段 $ranges';
      lines.add('- $label：${_formatDuration(minutes)}$rangeText');
    }
    return lines;
  }

  static Future<Map<String, String>> _loadLabelCategoryMap(
      SharedPreferences prefs,
      {required String categoriesKey}) async {
    final catList = prefs.getStringList(categoriesKey);
    if (catList == null || catList.isEmpty) return {};

    final map = <String, String>{};
    for (final str in catList) {
      try {
        final data = json.decode(str) as Map<String, dynamic>;
        final name = data['name'] as String?;
        if (name == null || name.isEmpty) continue;
        map[name] = name;
        final subs = data['subCategories'];
        if (subs is List) {
          for (final sub in subs) {
            if (sub is String && sub.isNotEmpty) {
              map[sub] = name;
            }
          }
        }
      } catch (_) {}
    }
    return map;
  }

  static String _formatDeltaMinutes(int delta) {
    if (delta == 0) return '持平';
    final sign = delta > 0 ? '+' : '';
    return '$sign${_formatDuration(delta.abs())}';
  }

  static String _hashDayData(
    SharedPreferences prefs,
    DateTime date, {
    required String slotsKey,
  }) {
    final key = dateKey(date);
    final slotsStr = prefs.getString(slotsKey) ?? '';
    try {
      final root = json.decode(slotsStr) as Map<String, dynamic>?;
      final day = root?[key];
      return json.encode(day ?? []).hashCode.toString();
    } catch (_) {
      return '${key}_empty'.hashCode.toString();
    }
  }

  static Future<List<_TimeBlock>> _loadDayTimeline(
    SharedPreferences prefs,
    DateTime date, {
    required String slotsKey,
  }) async {
    final key = dateKey(date);
    final slotsStr = prefs.getString(slotsKey);
    if (slotsStr == null) return [];

    try {
      final root = json.decode(slotsStr) as Map<String, dynamic>;
      final day = root[key];
      if (day is! List) return [];

      final entries = <_SlotEntry>[];
      for (final item in day) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final index = map['i'] as int?;
        final label = map['l'] as String?;
        if (index == null || label == null || label.isEmpty) continue;
        entries.add(_SlotEntry(
          index: index,
          label: label,
          fromCalendar: map['fc'] == true,
        ));
      }
      entries.sort((a, b) => a.index.compareTo(b.index));

      if (entries.isEmpty) return [];

      final merged = <_MutableBlock>[
        _MutableBlock(
          label: entries.first.label,
          fromCalendar: entries.first.fromCalendar,
          startIndex: entries.first.index,
          endIndex: entries.first.index + 1,
        ),
      ];

      for (var i = 1; i < entries.length; i++) {
        final e = entries[i];
        final last = merged.last;
        if (last.label == e.label &&
            last.fromCalendar == e.fromCalendar &&
            last.endIndex == e.index) {
          last.endIndex = e.index + 1;
        } else {
          merged.add(_MutableBlock(
            label: e.label,
            fromCalendar: e.fromCalendar,
            startIndex: e.index,
            endIndex: e.index + 1,
          ));
        }
      }

      return merged
          .map((b) => _TimeBlock(
                label: b.label,
                fromCalendar: b.fromCalendar,
                range: _indexRangeToString(b.startIndex, b.endIndex),
                startIndex: b.startIndex,
                endIndex: b.endIndex,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<String>> _loadUnrecordedGaps(
    SharedPreferences prefs,
    DateTime date, {
    int minSlots = 3,
    int maxGaps = 3,
    required String slotsKey,
  }) async {
    final key = dateKey(date);
    final slotsStr = prefs.getString(slotsKey);
    if (slotsStr == null) return const [];

    try {
      final root = json.decode(slotsStr) as Map<String, dynamic>;
      final day = root[key];
      if (day is! List) return const [];

      final recorded = <int>{};
      for (final item in day) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final index = map['i'] as int?;
        final label = map['l'] as String?;
        if (index == null || label == null || label.isEmpty) continue;
        recorded.add(index);
      }
      if (recorded.isEmpty) return const [];

      const dayStart = 42; // 07:00
      const dayEnd = 144; // 24:00
      final gaps = <_IndexRange>[];
      var gapStart = -1;

      void closeGap(int end) {
        if (gapStart < 0) return;
        final length = end - gapStart;
        if (length >= minSlots) {
          gaps.add(_IndexRange(gapStart, end));
        }
        gapStart = -1;
      }

      for (var i = dayStart; i < dayEnd; i++) {
        if (recorded.contains(i)) {
          closeGap(i);
        } else if (gapStart < 0) {
          gapStart = i;
        }
      }
      closeGap(dayEnd);

      gaps.sort((a, b) => (b.end - b.start).compareTo(a.end - a.start));
      return gaps
          .take(maxGaps)
          .map((g) => _indexRangeToString(g.start, g.end))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String _indexRangeToString(int start, int end) {
    String fmt(int idx) {
      final h = idx ~/ 6;
      final m = (idx % 6) * 10;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    }

    return '${fmt(start)}-${fmt(end)}';
  }

  static Future<_DayStats> _loadDayStats(
    SharedPreferences prefs,
    DateTime date, {
    required String slotsKey,
  }) async {
    final key = dateKey(date);
    final slotsStr = prefs.getString(slotsKey);
    if (slotsStr == null) return const _DayStats.empty();

    try {
      final root = json.decode(slotsStr) as Map<String, dynamic>;
      final day = root[key];
      if (day is! List) return const _DayStats.empty();

      final labelMinutes = <String, int>{};
      var userMinutes = 0;
      var calendarMinutes = 0;

      for (final item in day) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final label = map['l'] as String?;
        if (label == null || label.isEmpty) continue;

        final fromCalendar = map['fc'] == true;
        if (fromCalendar) {
          calendarMinutes += 10;
        } else {
          userMinutes += 10;
        }
        labelMinutes[label] = (labelMinutes[label] ?? 0) + 10;
      }

      return _DayStats(
        labelMinutes: labelMinutes,
        userMinutes: userMinutes,
        calendarMinutes: calendarMinutes,
      );
    } catch (_) {
      return const _DayStats.empty();
    }
  }

  static String _formatDuration(int minutes, {bool short = false}) {
    if (minutes < 60) {
      return short ? '$minutes分钟' : '$minutes 分钟';
    }
    final hours = minutes / 60;
    if (minutes % 60 == 0) {
      final h = minutes ~/ 60;
      return short ? '$h小时' : '$h 小时';
    }
    final text = hours.toStringAsFixed(1);
    return short ? '$text小时' : '$text 小时';
  }
}

class _CachedAi {
  final String hash;
  final String? body;
  final DateTime? createdAt;

  const _CachedAi({
    required this.hash,
    required this.body,
    required this.createdAt,
  });
}

class _DayStats {
  final Map<String, int> labelMinutes;
  final int userMinutes;
  final int calendarMinutes;

  const _DayStats({
    required this.labelMinutes,
    required this.userMinutes,
    required this.calendarMinutes,
  });

  const _DayStats.empty()
      : labelMinutes = const {},
        userMinutes = 0,
        calendarMinutes = 0;

  int get totalMinutes => userMinutes + calendarMinutes;

  List<MapEntry<String, int>> topLabels({int limit = 20}) {
    final entries = labelMinutes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).toList();
  }
}

class _SlotEntry {
  final int index;
  final String label;
  final bool fromCalendar;

  _SlotEntry({
    required this.index,
    required this.label,
    required this.fromCalendar,
  });
}

class _MutableBlock {
  final String label;
  final bool fromCalendar;
  final int startIndex;
  int endIndex;

  _MutableBlock({
    required this.label,
    required this.fromCalendar,
    required this.startIndex,
    required this.endIndex,
  });
}

class _TimeBlock {
  final String label;
  final bool fromCalendar;
  final String range;
  final int startIndex;
  final int endIndex;

  _TimeBlock({
    required this.label,
    required this.fromCalendar,
    required this.range,
    required this.startIndex,
    required this.endIndex,
  });
}

class _IndexRange {
  final int start;
  final int end;

  const _IndexRange(this.start, this.end);
}
