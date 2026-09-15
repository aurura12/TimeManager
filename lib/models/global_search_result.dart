import 'diary_kind.dart';

/// 全局搜索支持的内容模块。
enum GlobalSearchContentType {
  all,
  timeRecord,
  category,
  diary,
  travel,
  checkIn,
  target,
  aiReview,
}

extension GlobalSearchContentTypeX on GlobalSearchContentType {
  String get label => switch (this) {
        GlobalSearchContentType.all => '全部',
        GlobalSearchContentType.timeRecord => '时间记录',
        GlobalSearchContentType.category => '分类',
        GlobalSearchContentType.diary => '日记',
        GlobalSearchContentType.travel => '出行',
        GlobalSearchContentType.checkIn => '打卡',
        GlobalSearchContentType.target => '目标',
        GlobalSearchContentType.aiReview => 'AI复盘',
      };
}

/// 身份筛选。未绑定身份的共享本地数据只在“全部”中显示，避免误归属。
enum GlobalSearchIdentityFilter { all, guaiGuai, jingJing }

extension GlobalSearchIdentityFilterX on GlobalSearchIdentityFilter {
  String get label => switch (this) {
        GlobalSearchIdentityFilter.all => '全部身份',
        GlobalSearchIdentityFilter.guaiGuai => '乖乖',
        GlobalSearchIdentityFilter.jingJing => '晶晶',
      };

  DiaryKind? get kind => switch (this) {
        GlobalSearchIdentityFilter.all => null,
        GlobalSearchIdentityFilter.guaiGuai => DiaryKind.g,
        GlobalSearchIdentityFilter.jingJing => DiaryKind.j,
      };
}

/// 一个可导航的统一搜索结果。
///
/// [searchText] 仅用于匹配，不直接展示；[details] 是受长度限制的本地详情，
/// 用于点击结果后的详情页，避免搜索卡片携带或渲染无限长文本。
class GlobalSearchResult {
  static const int maxDetailsLength = 16000;

  final GlobalSearchContentType type;
  final DateTime? date;
  final String title;
  final String summary;
  final String searchText;
  final String? details;
  final DiaryKind? identityKind;
  final String? entityId;

  GlobalSearchResult({
    required this.type,
    required this.date,
    required this.title,
    required this.summary,
    String? searchText,
    this.details,
    this.identityKind,
    this.entityId,
  }) : searchText = (searchText ?? '$title\n$summary\n${details ?? ''}').trim();

  String get moduleLabel => type.label;

  String? get identityLabel => switch (identityKind) {
        DiaryKind.g => '乖乖',
        DiaryKind.j => '晶晶',
        null => null,
      };

  GlobalSearchResult copyWith({
    GlobalSearchContentType? type,
    DateTime? date,
    String? title,
    String? summary,
    String? searchText,
    String? details,
    DiaryKind? identityKind,
    String? entityId,
  }) {
    return GlobalSearchResult(
      type: type ?? this.type,
      date: date ?? this.date,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      searchText: searchText ?? this.searchText,
      details: details ?? this.details,
      identityKind: identityKind ?? this.identityKind,
      entityId: entityId ?? this.entityId,
    );
  }
}

/// 对已建立的本地结果做纯内存筛选。
///
/// 单独抽出这一层，核心搜索可以在不启动同步、不依赖 Flutter 页面生命周期的
/// 情况下测试；数据读取由 [UnifiedSearchService] 负责。
class GlobalSearchIndex {
  static const int maxResults = 200;
  static const int maxIndexedEntries = 4000;

  final List<GlobalSearchResult> entries;

  GlobalSearchIndex(Iterable<GlobalSearchResult> entries)
      : entries = List.unmodifiable(
          entries.take(maxIndexedEntries),
        );

  List<GlobalSearchResult> search(
    String query, {
    GlobalSearchContentType contentType = GlobalSearchContentType.all,
    GlobalSearchIdentityFilter identity = GlobalSearchIdentityFilter.all,
    DateTime? startDate,
    DateTime? endDate,
    int limit = maxResults,
  }) {
    final normalized = _normalize(query);
    if (normalized.isEmpty) return const [];

    final start = _day(startDate);
    final end = _day(endDate);
    final filtered = <GlobalSearchResult>[];
    for (final entry in entries) {
      if (contentType != GlobalSearchContentType.all &&
          entry.type != contentType) {
        continue;
      }
      final identityKind = identity.kind;
      if (identityKind != null && entry.identityKind != identityKind) {
        continue;
      }
      if (!_dateInRange(entry.date, start: start, end: end)) continue;
      if (!_normalize(entry.searchText).contains(normalized)) continue;
      filtered.add(entry);
    }

    filtered.sort((a, b) {
      final dateCompare = _compareNullableDatesDescending(a.date, b.date);
      if (dateCompare != 0) return dateCompare;
      final typeCompare = a.type.index.compareTo(b.type.index);
      if (typeCompare != 0) return typeCompare;
      return a.title.compareTo(b.title);
    });
    final safeLimit = limit.clamp(1, maxResults);
    return List.unmodifiable(filtered.take(safeLimit));
  }

  static String _normalize(String value) => value.trim().toLowerCase();

  static DateTime? _day(DateTime? value) {
    if (value == null) return null;
    return DateTime(value.year, value.month, value.day);
  }

  static bool _dateInRange(
    DateTime? value, {
    required DateTime? start,
    required DateTime? end,
  }) {
    // 无日期的分类/目标只在“全部日期”时展示；选定范围时不假定其创建日期。
    if (value == null) return start == null && end == null;
    final date = _day(value)!;
    if (start != null && date.isBefore(start)) return false;
    if (end != null && date.isAfter(end)) return false;
    return true;
  }

  static int _compareNullableDatesDescending(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }
}
