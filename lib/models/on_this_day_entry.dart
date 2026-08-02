/// 往年今天（同月同日）的记录摘要
class OnThisDayEntry {
  final int year; // 年份，如 2025
  final int totalMinutes; // 当天时间记录总时长（分钟）
  final List<ActivitySummary> activities; // 活动列表（按时长降序）

  // 以下字段由 OnThisDayService 收集后填充（可变）
  // 日记字段存的是剥离 front matter 后的完整正文，卡片默认截断显示、点击可展开
  String? diaryGuaiGuai; // 乖乖那天的日记（完整正文）
  String? diaryJingJing; // 晶晶那天的日记（完整正文）
  String? travelLocation; // 那天去了哪
  String? travelEvent; // 那天做了什么

  OnThisDayEntry({
    required this.year,
    required this.totalMinutes,
    required this.activities,
  });

  bool get hasDiary =>
      diaryGuaiGuai != null || diaryJingJing != null;
  bool get hasTravel => travelLocation != null;

  String get yearsAgoLabel {
    final diff = DateTime.now().year - year;
    if (diff == 1) return '去年';
    return '$diff年前';
  }
}

/// 单项活动时长
class ActivitySummary {
  final String label; // 活动名称
  final int minutes; // 分钟数

  const ActivitySummary({required this.label, required this.minutes});
}
