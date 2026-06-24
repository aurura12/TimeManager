import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'siliconflow_ai_service.dart';

enum DailyReviewAiError {
  noApiKey,
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
      case DailyReviewAiError.networkFailed:
        return 'AI 生成失败，请检查网络后重试。';
      case DailyReviewAiError.timeout:
        return 'AI 响应超时（可能网络较慢或后台受限），请打开 App 后点击重新生成。';
      case null:
        return '未知错误';
    }
  }
}

class DailyReviewSummaryBuilder {
  static const _cachePrefix = 'daily_review_ai_cache_';
  static const payloadPrefix = 'daily_review:';

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
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_cachePrefix)) {
        await prefs.remove(key);
      }
    }
  }

  static String dateKey(DateTime date) =>
      '${date.year}-${date.month}-${date.day}';

  static Future<DailyReviewAiResult?> loadCachedAi(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final dataHash = _hashDayData(prefs, date);
    final body = await _loadCachedAiBody(
      prefs: prefs,
      date: date,
      dataHash: dataHash,
    );
    if (body == null) return null;
    return DailyReviewAiResult(
      date: date,
      title: _titleForDate(date),
      body: body,
      fromCache: true,
    );
  }

  /// 仅 AI 生成复盘，无本地写死兜底
  static Future<DailyReviewAiResult> fetchAiForDate(
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final todayStats = await _loadDayStats(prefs, date);
    final yesterday = date.subtract(const Duration(days: 1));
    final yesterdayStats = await _loadDayStats(prefs, yesterday);
    final dataHash = _hashDayData(prefs, date);
    final title = _titleForDate(date);

    if (!SiliconFlowAiService.hasApiKeyConfigured) {
      return DailyReviewAiResult(
        date: date,
        title: title,
        error: DailyReviewAiError.noApiKey,
      );
    }

    if (!forceRefresh) {
      final cached = await _loadCachedAiBody(
        prefs: prefs,
        date: date,
        dataHash: dataHash,
      );
      if (cached != null) {
        return DailyReviewAiResult(
          date: date,
          title: title,
          body: cached,
          fromCache: true,
        );
      }
    }

    final prompt = _buildAiPrompt(
      date: date,
      todayStats: todayStats,
      yesterdayStats: yesterdayStats,
      timeline: await _loadDayTimeline(prefs, date),
      unrecordedGaps: await _loadUnrecordedGaps(prefs, date),
    );

    final aiText = await SiliconFlowAiService.generateDailyReview(
      userPrompt: prompt,
    );

    if (aiText == null || aiText.isEmpty) {
      return DailyReviewAiResult(
        date: date,
        title: title,
        error: SiliconFlowAiService.lastCallTimedOut
            ? DailyReviewAiError.timeout
            : DailyReviewAiError.networkFailed,
      );
    }

    await prefs.setString(
      '$_cachePrefix${dateKey(date)}',
      json.encode({'hash': dataHash, 'body': aiText}),
    );

    return DailyReviewAiResult(
      date: date,
      title: title,
      body: aiText,
      fromCache: false,
    );
  }

  static String _titleForDate(DateTime date) =>
      '${date.month}月${date.day}日 · 今日复盘';

  static Future<String?> _loadCachedAiBody({
    required SharedPreferences prefs,
    required DateTime date,
    required String dataHash,
  }) async {
    final cacheKey = '$_cachePrefix${dateKey(date)}';
    final cachedRaw = prefs.getString(cacheKey);
    if (cachedRaw == null) return null;
    try {
      final cached = json.decode(cachedRaw) as Map<String, dynamic>;
        if (cached['hash'] == dataHash) {
          final body = cached['body'] as String?;
          if (body != null &&
              body.isNotEmpty &&
              !SiliconFlowAiService.looksLikeThinkingProcess(body)) {
            return body;
          }
        }
    } catch (_) {}
    return null;
  }

  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  static String _buildAiPrompt({
    required DateTime date,
    required _DayStats todayStats,
    required _DayStats yesterdayStats,
    required List<_TimeBlock> timeline,
    required List<String> unrecordedGaps,
  }) {
    final weekday = _weekdayLabels[date.weekday - 1];
    final buffer = StringBuffer();
    buffer.writeln('请根据下方【原始数据】，为用户写「${date.month}月${date.day}日（$weekday）」的每日复盘正文。');
    buffer.writeln();
    buffer.writeln('【原始数据】');
    buffer.writeln(
        '昨日记录总时长：${_formatDuration(yesterdayStats.totalMinutes)}');
    buffer.writeln(
        '今日记录总时长：${_formatDuration(todayStats.totalMinutes)}');
    buffer.writeln(
        '今日自主安排：${_formatDuration(todayStats.userMinutes)}，日历/会议：${_formatDuration(todayStats.calendarMinutes)}');

    if (yesterdayStats.labelMinutes.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('昨日主要事项：');
      for (final e in yesterdayStats.topLabels(limit: 5)) {
        buffer.writeln('- ${e.key}：${_formatDuration(e.value)}');
      }
    }

    if (todayStats.labelMinutes.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('今日各事项时长（完整列表）：');
      for (final e in todayStats.topLabels(limit: 20)) {
        buffer.writeln('- ${e.key}：${_formatDuration(e.value)}');
      }
    }

    buffer.writeln();
    if (timeline.isEmpty) {
      buffer.writeln('今日时间轴：无记录。');
    } else {
      buffer.writeln('今日时间轴（按发生顺序，须据此复述）：');
      for (final block in timeline) {
        final tag = block.fromCalendar ? '日历' : '自主';
        final duration = _formatDuration((block.endIndex - block.startIndex) * 10);
        buffer.writeln('- ${block.range} ${block.label}（$tag，$duration）');
      }
    }

    buffer.writeln();
    if (unrecordedGaps.isEmpty) {
      buffer.writeln('较长空白时段：无明显空白（或记录较连续）。');
    } else {
      buffer.writeln('较长未记录时段（用户未标注在做什么）：');
      for (final gap in unrecordedGaps) {
        buffer.writeln('- $gap');
      }
    }

    buffer.writeln();
    buffer.writeln('【输出要求】');
    buffer.writeln('请用 2～4 段自然段写出复盘。必须点名上述具体事项名称和时段，'
        '不要泛泛总结。对比昨日时引用具体数字或事项名。');

    return buffer.toString();
  }

  static String _hashDayData(SharedPreferences prefs, DateTime date) {
    final key = dateKey(date);
    final slotsStr = prefs.getString('daily_slots') ?? '';
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
    DateTime date,
  ) async {
    final key = dateKey(date);
    final slotsStr = prefs.getString('daily_slots');
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
  }) async {
    final key = dateKey(date);
    final slotsStr = prefs.getString('daily_slots');
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
    DateTime date,
  ) async {
    final key = dateKey(date);
    final slotsStr = prefs.getString('daily_slots');
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

  List<MapEntry<String, int>> topLabels({int limit = 2}) {
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
