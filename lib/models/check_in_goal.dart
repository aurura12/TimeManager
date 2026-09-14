import 'package:flutter/material.dart';

import 'check_in_record.dart';

import 'known_google_users.dart';
import '../theme/app_semantic_colors.dart';

/// 打卡目标周期
enum CheckInPeriod {
  daily('daily', '每天'),
  weekly('weekly', '每周'),
  monthly('monthly', '每月');

  const CheckInPeriod(this.storageKey, this.label);
  final String storageKey;
  final String label;

  static CheckInPeriod fromKey(String? key) {
    return CheckInPeriod.values.firstWhere(
      (p) => p.storageKey == key,
      orElse: () => CheckInPeriod.daily,
    );
  }
}

/// 打卡目标可选图标（须为 const，release 构建才能 tree-shake 字体）
class CheckInGoalIcons {
  CheckInGoalIcons._();

  static const List<IconData> options = [
    Icons.directions_run,
    Icons.fitness_center,
    Icons.menu_book,
    Icons.self_improvement,
    Icons.pool,
    Icons.pedal_bike,
    Icons.nightlight,
    Icons.restaurant,
    Icons.work,
    Icons.pets,
  ];

  static IconData fromCodePoint(int? code) {
    if (code == null) return Icons.flag;
    for (final icon in options) {
      if (icon.codePoint == code) return icon;
    }
    return Icons.flag;
  }
}

/// 打卡目标
class CheckInGoal {
  const CheckInGoal({
    required this.id,
    required this.ownerId,
    required this.ownerEmail,
    this.ownerDisplayName,
    required this.name,
    required this.description,
    required this.color,
    required this.icon,
    required this.period,
    required this.targetCount,
    this.records = const [],
    this.requireLocation = true,
    this.requirePhoto = true,
    this.startDate,
    this.endDate,
    this.isArchived = false,
    this.archivedAt,
    this.updatedAt = 0,
  });

  final String id;
  final String ownerId;
  final String ownerEmail;
  final String? ownerDisplayName;
  final String name;
  final String description;
  final Color color;
  final IconData icon;
  final CheckInPeriod period;
  final int targetCount;
  final List<CheckInRecord> records;
  final bool requireLocation;
  final bool requirePhoto;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool isArchived;
  final DateTime? archivedAt;

  /// 目标元数据最后修改时间（毫秒时间戳），用于跨端合并判断谁更新。
  ///
  /// 记录（[CheckInRecord]）本来就有 timestamp 可比，但目标在此之前完全没有时间
  /// 信息，导致合并只能"远端优先"，本地对已有目标的编辑（改名/描述/图标/周期/
  /// 次数）必然被远端旧值覆盖。旧数据为 0，须在本地与远端合并后再补齐，不能在
  /// 拉取远端前把旧本地数据伪装成最新修改。
  final int updatedAt;

  String get ownerLabel => KnownGoogleUsers.displayLabel(
        email: ownerEmail,
        googleDisplayName: ownerDisplayName,
      );

  bool isOwnedBy(String userId, {String? email}) =>
      ownerId == userId ||
      (email != null &&
          KnownGoogleUsers.normalizeEmail(ownerEmail) ==
              KnownGoogleUsers.normalizeEmail(email));

  /// 是否已过期。
  ///
  /// [endDate] 是"结束日期"（只含年月日），按含当天处理：结束日当天仍可打卡，
  /// 只有过了结束日 24:00 才算过期。此前直接用 `endDate.isBefore(now)` 比较时刻，
  /// 而 endDate 存的是结束日 00:00，导致结束日当天目标就被判过期、从活动列表消失。
  bool get isExpired {
    final end = endDate;
    if (end == null) return false;
    final endOfDayExclusive = DateTime(end.year, end.month, end.day + 1);
    return !DateTime.now().isBefore(endOfDayExclusive);
  }

  bool get isActive => !isArchived && !isExpired;

  int get totalCheckIns => records.length;

  int currentPeriodCountFor(String? userId, {String? email}) {
    final now = DateTime.now();
    return records
        .where((r) =>
            _matchesUser(r, userId, email) &&
            _isInCurrentPeriod(r.timestamp, now))
        .length;
  }

  bool isCompletedTodayBy(String userId, {String? email}) {
    final now = DateTime.now();
    return records.any(
      (r) => _matchesUser(r, userId, email) && _isSameDay(r.timestamp, now),
    );
  }

  /// 连续打卡天数。
  ///
  /// 同一天多次打卡只算一天；今天尚未打卡时，允许从昨天开始计算（保持原语义）。
  int streakDaysFor(String userId, {String? email}) {
    // 先按"天"去重：否则同一天的重复记录会让后续日期对不上而提前中断。
    final days = <DateTime>{};
    for (final r in records) {
      if (!_matchesUser(r, userId, email)) continue;
      days.add(DateTime(r.timestamp.year, r.timestamp.month, r.timestamp.day));
    }
    if (days.isEmpty) return 0;

    final sortedDays = days.toList()..sort((a, b) => b.compareTo(a));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    var cursor = today;
    if (sortedDays.first != today) {
      // 今天还没打卡：只有当最近一次打卡是昨天时才继续算连续
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      if (sortedDays.first != yesterday) return 0;
      cursor = yesterday;
    }

    var streak = 0;
    for (final day in sortedDays) {
      if (day != cursor) break;
      streak++;
      cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
    }
    return streak;
  }

  double progressFor(String? userId) {
    final count = currentPeriodCountFor(userId);
    return targetCount > 0 ? (count / targetCount).clamp(0.0, 1.0) : 0;
  }

  // 兼容旧 UI 调用（默认统计全部用户的记录）
  int get currentPeriodCount => currentPeriodCountFor(null);
  @Deprecated(
      'Use isCompletedTodayBy(userId) instead. This getter checks all users.')
  bool get isCompletedToday =>
      records.any((r) => _isSameDay(r.timestamp, DateTime.now()));
  int get streakDays => streakDaysFor(ownerId);
  double get progress => progressFor(null);

  bool _matchesUser(CheckInRecord r, String? userId, String? email) {
    // userId 与 email 均为空表示统计所有用户
    if (userId == null && email == null) return true;
    if (userId != null && r.userId == userId) return true;
    if (email != null &&
        KnownGoogleUsers.normalizeEmail(r.userEmail) ==
            KnownGoogleUsers.normalizeEmail(email)) {
      return true;
    }
    return false;
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isInCurrentPeriod(DateTime ts, DateTime now) {
    switch (period) {
      case CheckInPeriod.daily:
        return _isSameDay(ts, now);
      case CheckInPeriod.weekly:
        final weekStart = now.subtract(Duration(days: now.weekday - 1));
        final tsDay = DateTime(ts.year, ts.month, ts.day);
        final startDay =
            DateTime(weekStart.year, weekStart.month, weekStart.day);
        final endDay = startDay.add(const Duration(days: 6)); // 本周日
        return !tsDay.isBefore(startDay) && !tsDay.isAfter(endDay);
      case CheckInPeriod.monthly:
        return ts.year == now.year && ts.month == now.month;
    }
  }

  CheckInGoal withoutRecords() {
    return copyWith(records: const []);
  }

  CheckInGoal copyWith({
    String? id,
    String? ownerId,
    String? ownerEmail,
    String? ownerDisplayName,
    String? name,
    String? description,
    Color? color,
    IconData? icon,
    CheckInPeriod? period,
    int? targetCount,
    List<CheckInRecord>? records,
    bool? requireLocation,
    bool? requirePhoto,
    DateTime? startDate,
    DateTime? endDate,
    bool? isArchived,
    DateTime? archivedAt,
    int? updatedAt,
  }) {
    return CheckInGoal(
      id: id ?? this.id,
      ownerId: ownerId ?? this.ownerId,
      ownerEmail: ownerEmail ?? this.ownerEmail,
      ownerDisplayName: ownerDisplayName ?? this.ownerDisplayName,
      name: name ?? this.name,
      description: description ?? this.description,
      color: color ?? this.color,
      icon: icon ?? this.icon,
      period: period ?? this.period,
      targetCount: targetCount ?? this.targetCount,
      records: records ?? this.records,
      requireLocation: requireLocation ?? this.requireLocation,
      requirePhoto: requirePhoto ?? this.requirePhoto,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      isArchived: isArchived ?? this.isArchived,
      archivedAt: archivedAt ?? this.archivedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'owner_id': ownerId,
      'owner_email': ownerEmail,
      if (ownerDisplayName != null) 'owner_display_name': ownerDisplayName,
      'name': name,
      'description': description,
      'color': color.toARGB32(),
      'icon': icon.codePoint,
      'period': period.storageKey,
      'target_count': targetCount,
      'require_location': requireLocation,
      'require_photo': requirePhoto,
      if (startDate != null) 'start_date': startDate!.toIso8601String(),
      if (endDate != null) 'end_date': endDate!.toIso8601String(),
      'is_archived': isArchived,
      if (archivedAt != null) 'archived_at': archivedAt!.toIso8601String(),
      'updated_at': updatedAt,
    };
  }

  factory CheckInGoal.fromJson(Map<String, dynamic> json) {
    return CheckInGoal(
      id: json['id']?.toString() ?? '',
      ownerId: json['owner_id']?.toString() ?? '',
      ownerEmail: json['owner_email']?.toString() ?? '',
      ownerDisplayName: json['owner_display_name']?.toString(),
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      // 与 Category 同理：颜色只能是不透明实色
      color: AppSemanticColors.opaque(Color(
          json['color'] as int? ?? AppSemanticColors.brandSurface.toARGB32())),
      icon: CheckInGoalIcons.fromCodePoint(json['icon'] as int?),
      period: CheckInPeriod.fromKey(json['period']?.toString()),
      targetCount: json['target_count'] as int? ?? 1,
      requireLocation: json['require_location'] as bool? ?? true,
      requirePhoto: json['require_photo'] as bool? ?? true,
      startDate: json['start_date'] != null
          ? DateTime.tryParse(json['start_date'].toString())
          : null,
      endDate: json['end_date'] != null
          ? DateTime.tryParse(json['end_date'].toString())
          : null,
      isArchived: json['is_archived'] as bool? ?? false,
      archivedAt: json['archived_at'] != null
          ? DateTime.tryParse(json['archived_at'].toString())
          : null,
      updatedAt: _asInt(json['updated_at']),
    );
  }

  /// 时间戳字段宽松解析：旧数据缺失、或历史写入的是字符串/浮点，都不应让整条
  /// 目标解析失败（否则整份远端数据都会被丢弃）。
  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return num.tryParse(value.trim())?.toInt() ?? 0;
    return 0;
  }
}
