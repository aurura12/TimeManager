import 'package:flutter/material.dart';

import 'check_in_record.dart';

import 'known_google_users.dart';

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

  String get ownerLabel => KnownGoogleUsers.displayLabel(
        email: ownerEmail,
        googleDisplayName: ownerDisplayName,
      );

  bool isOwnedBy(String userId) => ownerId == userId;

  bool get isActive =>
      !isArchived && (endDate == null || endDate!.isAfter(DateTime.now()));

  bool get isExpired => endDate != null && endDate!.isBefore(DateTime.now());

  int get totalCheckIns => records.length;

  int currentPeriodCountFor(String? userId) {
    final now = DateTime.now();
    return records
        .where((r) =>
            (userId == null || r.userId == userId) &&
            _isInCurrentPeriod(r.timestamp, now))
        .length;
  }

  bool isCompletedTodayBy(String userId) {
    final now = DateTime.now();
    return records.any(
      (r) => r.userId == userId && _isSameDay(r.timestamp, now),
    );
  }

  int streakDaysFor(String userId) {
    final userRecords = records
        .where((r) => r.userId == userId)
        .map((r) => r.timestamp)
        .toList()
      ..sort((a, b) => b.compareTo(a));
    if (userRecords.isEmpty) return 0;

    int streak = 0;
    var checkDate = DateTime.now();
    // 仅在第一次迭代允许跳过"今天"（处理今天尚未打卡的情况）
    bool firstDaySkipAllowed = true;
    for (final ts in userRecords) {
      if (_isSameDay(ts, checkDate)) {
        streak++;
        checkDate = checkDate.subtract(const Duration(days: 1));
      } else if (firstDaySkipAllowed &&
          _isSameDay(
              ts, checkDate.subtract(const Duration(days: 1)))) {
        // 允许从昨天开始计算 streak（今天可能还没打卡）
        streak++;
        checkDate = DateTime(ts.year, ts.month, ts.day);
        checkDate = checkDate.subtract(const Duration(days: 1));
        firstDaySkipAllowed = false;
      } else {
        break;
      }
    }
    return streak;
  }

  double progressFor(String? userId) {
    final count = currentPeriodCountFor(userId);
    return targetCount > 0 ? (count / targetCount).clamp(0.0, 1.0) : 0;
  }

  // 兼容旧 UI 调用（默认统计全部用户的记录）
  int get currentPeriodCount => currentPeriodCountFor(null);
  @Deprecated('Use isCompletedTodayBy(userId) instead. This getter checks all users.')
  bool get isCompletedToday =>
      records.any((r) => _isSameDay(r.timestamp, DateTime.now()));
  int get streakDays => streakDaysFor(ownerId);
  double get progress => progressFor(null);

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
        return !tsDay.isBefore(startDay);
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
      color: Color(json['color'] as int? ?? 0xFF96B462),
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
    );
  }
}
