import '../models/diary_kind.dart';
import '../models/on_this_day_entry.dart';
import '../models/travel_record.dart';
import '../providers/time_provider.dart';
import 'diary_local_store.dart';
import 'diary_search_service.dart';
import 'travel_local_store.dart';

/// 收集"那年今日"的三数据源（时间记录 + 日记 + 出行），按年份合并
class OnThisDayService {
  static const int maxYears = 5; // 往前查几年
  static const int maxSummaryChars = 80; // 日记摘要截取长度

  /// 收集往年今日所有数据，返回有记录的年份列表（从近到远）。
  ///
  /// 三种数据源任一命中即创建 entry：
  /// - 时间记录：`TimeProvider.getSlotsForDate` 按日期查询
  /// - 日记：优先搜索缓存（同步），未命中读本地草稿（异步）
  /// - 出行：读整份出行文档（解析一次），按日期键匹配
  static Future<List<OnThisDayEntry>> collectEntries(
    TimeProvider provider,
  ) async {
    final now = DateTime.now();
    final month = now.month;
    final day = now.day;
    final currentYear = now.year;
    final startYear = currentYear - maxYears;

    // 年份范围：currentYear-1 到 currentYear-maxYears，且不低于 2020
    final years = <int>[
      for (int y = currentYear - 1; y >= startYear && y >= 2020; y--) y,
    ];
    if (years.isEmpty) return [];

    // 按年份收集三数据源结果
    final entriesByYear = <int, OnThisDayEntry>{};

    // ① 时间记录（同步，内存 Map 查询）
    for (final year in years) {
      // 注意：不能直接 DateTime(year, month, day)——非闰年 2/29 会自动进位成 3/1，
      // 导致日期键错位。用字符串拼接保证精确匹配。
      final dateKey = _dateKeyOf(year, month, day);
      final slots = provider.getSlotsForDate(dateKey);
      if (slots == null || slots.isEmpty) continue;

      final stats = <String, int>{}; // label -> 10分钟槽位数
      for (final slot in slots) {
        if (slot.recorded && slot.label != null && slot.label!.isNotEmpty) {
          stats[slot.label!] = (stats[slot.label!] ?? 0) + 1;
        }
      }

      if (stats.isEmpty) continue;

      final activities = stats.entries
          .map((e) => ActivitySummary(label: e.key, minutes: e.value * 10))
          .toList()
        ..sort((a, b) => b.minutes.compareTo(a.minutes));

      final totalSlots = stats.values.fold<int>(0, (sum, c) => sum + c);
      entriesByYear[year] = OnThisDayEntry(
        year: year,
        totalMinutes: totalSlots * 10,
        activities: activities,
      );
    }

    // ② 日记（异步，逐个年份读取，命中则确保 entry 存在）
    for (final year in years) {
      final dateKey = _dateKeyOf(year, month, day);
      final g = await _readDiary(DiaryKind.g, dateKey);
      final j = await _readDiary(DiaryKind.j, dateKey);
      if (g == null && j == null) continue;

      final entry = entriesByYear.putIfAbsent(
        year,
        () => OnThisDayEntry(year: year, totalMinutes: 0, activities: []),
      );
      entry.diaryGuaiGuai = g;
      entry.diaryJingJing = j;
    }

    // ③ 出行（异步，整份解析一次复用）
    final travelMap = await _loadTravelMap();
    for (final year in years) {
      final travel = travelMap[_dateKeyOf(year, month, day)];
      if (travel == null) continue;

      final entry = entriesByYear.putIfAbsent(
        year,
        () => OnThisDayEntry(year: year, totalMinutes: 0, activities: []),
      );
      entry.travelLocation = travel.location;
      entry.travelEvent = travel.event;
    }

    // 按年份从近到远返回
    final result = years
        .where(entriesByYear.containsKey)
        .map((y) => entriesByYear[y]!)
        .toList();
    return result;
  }

  static Future<String?> _readDiary(DiaryKind kind, String dateKey) async {
    // 从日期键解析出 DateTime（yyyy-MM-dd）
    final date = DateTime.parse(dateKey);
    // 通道 A：搜索缓存（同步，App 启动后台索引）
    if (DiarySearchService.isLoaded) {
      final cached = DiarySearchService.getCachedContent(kind.code, date);
      if (cached != null && cached.trim().isNotEmpty) {
        return summarizeDiary(cached);
      }
    }
    // 通道 B：本地草稿（异步）
    final draft = await DiaryLocalStore.loadDraftBody(kind, date);
    if (draft != null && draft.trim().isNotEmpty) return summarizeDiary(draft);
    return null;
  }

  /// 剥离 front matter + 空行，取前 N 字作为摘要
  ///
  /// 与项目现有 _extractBodyFromMarkdown（diary_screen.dart）同款正则语义，
  /// 额外支持 CRLF 换行（Windows 编辑的日记文件）。
  static String? summarizeDiary(String content) {
    final match =
        RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?').firstMatch(content);
    final text = (match == null ? content : content.substring(match.end)).trim();
    if (text.isEmpty) return null;
    if (text.length <= maxSummaryChars) return text;
    return '${text.substring(0, maxSummaryChars)}…';
  }

  /// 读取整份出行记录文档，返回按日期键索引的 map
  static Future<Map<String, TravelRecord>> _loadTravelMap() async {
    final markdown = await TravelLocalStore.loadDraft();
    if (markdown == null || markdown.trim().isEmpty) return {};
    try {
      final doc = TravelRecordsDocument.fromMarkdown(markdown);
      return {for (final r in doc.records) r.dateKey: r};
    } catch (_) {
      return {};
    }
  }

  /// 统一日期键格式 yyyy-MM-dd（与 TimeProvider._getDateKey 一致）
  static String dateKeyOf(DateTime date) {
    return _dateKeyOf(date.year, date.month, date.day);
  }

  /// 由 year/month/day 直接拼接日期键。
  /// 不使用 DateTime(year, month, day) 构造，避免非闰年 2/29 自动进位成 3/1。
  static String _dateKeyOf(int year, int month, int day) {
    return '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
  }
}
