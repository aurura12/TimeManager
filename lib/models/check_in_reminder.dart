/// 单个打卡目标的提醒设置。
///
/// **设备本地**，不参与 Git 同步：通知权限、精确闹钟能力、勿扰与通道重要性都是
/// 每台设备各自的，同步过来会出现「设置说开着但这台设备发不出来」。
/// 而且 `CheckInGoal` 是白名单序列化 + 整对象覆盖合并，往目标模型上加字段会被
/// 老版本的任意一次推送静默抹掉。
library;

class CheckInReminderSettings {
  const CheckInReminderSettings({
    required this.goalId,
    required this.enabled,
    required this.hour,
    required this.minute,
    this.goalName = '',
    this.startDateMs,
    this.endDateMs,
    this.archived = false,
  });

  const CheckInReminderSettings.disabled(this.goalId)
      : enabled = false,
        hour = defaultHour,
        minute = defaultMinute,
        goalName = '',
        startDateMs = null,
        endDateMs = null,
        archived = false;

  static const int defaultHour = 21;
  static const int defaultMinute = 0;

  /// 目标 id。目标 id 是毫秒时间戳字符串，只作业务键，**不直接当通知 id**
  /// （会溢出 int32 且有冲突风险）。
  final String goalId;

  final bool enabled;
  final int hour;
  final int minute;

  /// 冗余保存目标名与日期区间。
  ///
  /// 目的是让「回到前台时的自检」不需要加载整份打卡文档就能判断该不该提醒、
  /// 以及通知标题写什么。用户每次在编辑页保存都会刷新；打卡页打开时也会用真实
  /// 目标列表覆盖一次。
  final String goalName;
  final int? startDateMs;
  final int? endDateMs;

  /// 目标是否已归档。
  ///
  /// 必须冗余保存：回到前台的自检不加载目标列表，若不知道已归档就会一直提醒。
  final bool archived;

  /// 展示用的 `HH:mm`。与项目其它位置一致：手写两位补零，不走 intl。
  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// 该提醒在 [now] 是否应当存在。
  bool isEligibleAt(DateTime now) {
    if (!enabled) return false;
    if (archived) return false;
    final end = endDateMs;
    if (end != null) {
      // `endDate` 是结束日当天 00:00，而结束日当天仍算有效（与
      // `CheckInGoal.allowsCheckInAt` 同一套口径），所以必须按"日"比较：
      // 按具体时刻比较会让结束日从零点起整天都不提醒。
      final endDay = DateTime.fromMillisecondsSinceEpoch(end);
      final today = DateTime(now.year, now.month, now.day);
      if (today.isAfter(DateTime(endDay.year, endDay.month, endDay.day))) {
        return false;
      }
    }
    final start = startDateMs;
    if (start != null && now.isBefore(DateTime.fromMillisecondsSinceEpoch(start))) {
      return false;
    }
    return true;
  }

  CheckInReminderSettings copyWith({
    bool? enabled,
    int? hour,
    int? minute,
    String? goalName,
    bool? archived,
    Object? startDateMs = _unset,
    Object? endDateMs = _unset,
  }) {
    return CheckInReminderSettings(
      goalId: goalId,
      enabled: enabled ?? this.enabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      goalName: goalName ?? this.goalName,
      archived: archived ?? this.archived,
      startDateMs: identical(startDateMs, _unset)
          ? this.startDateMs
          : startDateMs as int?,
      endDateMs:
          identical(endDateMs, _unset) ? this.endDateMs : endDateMs as int?,
    );
  }

  /// 与 `CheckInGoal.copyWith` 一致的哨兵：可空字段允许显式传 null 清空。
  static const Object _unset = Object();

  @override
  bool operator ==(Object other) =>
      other is CheckInReminderSettings &&
      other.goalId == goalId &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute &&
      other.goalName == goalName &&
      other.startDateMs == startDateMs &&
      other.endDateMs == endDateMs &&
      other.archived == archived;

  @override
  int get hashCode => Object.hash(
        goalId,
        enabled,
        hour,
        minute,
        goalName,
        startDateMs,
        endDateMs,
        archived,
      );

  @override
  String toString() => 'CheckInReminderSettings($goalId, enabled: $enabled, '
      'time: $timeLabel, name: $goalName)';
}

/// 保存提醒设置的结果。UI 只需要知道"成了没"以及该给用户看什么。
class CheckInReminderResult {
  const CheckInReminderResult({this.ok = true, this.message});

  const CheckInReminderResult.failed([this.message]) : ok = false;

  final bool ok;

  /// 可直接展示的中文说明；为 null 表示无需提示。
  final String? message;
}
