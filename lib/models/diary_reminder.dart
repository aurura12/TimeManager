/// 写日记提醒的设置与运行状态。
///
/// 这里只放纯数据：不引用任何通知插件的类型，方便单测与 UI 直接使用。
library;

/// 提醒设置：开关 + 每天的时:分。
class DiaryReminderSettings {
  const DiaryReminderSettings({
    required this.enabled,
    required this.hour,
    required this.minute,
  });

  /// 未设置过时的默认提醒时间。
  const DiaryReminderSettings.defaults()
      : enabled = false,
        hour = defaultHour,
        minute = defaultMinute;

  static const int defaultHour = 21;
  static const int defaultMinute = 0;

  final bool enabled;
  final int hour;
  final int minute;

  /// 展示用的 `HH:mm`。与项目其余位置一致：手写两位补零，不走 intl。
  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  DiaryReminderSettings copyWith({bool? enabled, int? hour, int? minute}) {
    return DiaryReminderSettings(
      enabled: enabled ?? this.enabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DiaryReminderSettings &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(enabled, hour, minute);

  @override
  String toString() =>
      'DiaryReminderSettings(enabled: $enabled, time: $timeLabel)';
}

/// 提醒当前处于什么问题状态。UI 只依据它决定展示什么，不再依赖日志判断成败。
enum DiaryReminderIssue {
  /// 一切正常。
  none,

  /// 非 Android：整个分区不展示。
  unsupportedPlatform,

  /// 尚未选择用户身份，开关必须先置灰。
  identityUnavailable,

  /// 读取设置本身失败。此时不敢替用户判断状态。
  statusUnavailable,

  /// 系统时区不可用。绝不回退 UTC 排程，直接暂停提醒。
  timezoneUnavailable,

  /// 通知权限未授予。
  notificationsDenied,

  /// 通知通道被用户关闭。
  channelDisabled,

  /// 没有精确闹钟能力，已降级为不精确排程，可能延迟。
  exactAlarmDenied,

  /// 排程调用失败。
  scheduleFailed,
}

/// 提醒的完整状态快照。
class DiaryReminderStatus {
  const DiaryReminderStatus({
    required this.settings,
    this.issue = DiaryReminderIssue.none,
    this.message,
    this.scheduled = false,
    this.exactAllowed = false,
    this.notificationAllowed = true,
    this.channelImportance,
    this.timezoneName,
    this.nextFireAt,
  });

  /// 读取设置失败时的安全兜底：抽屉必须能正常打开。
  const DiaryReminderStatus.fallback()
      : settings = const DiaryReminderSettings.defaults(),
        issue = DiaryReminderIssue.statusUnavailable,
        message = '读取提醒设置失败，请查看运行日志',
        scheduled = false,
        exactAllowed = false,
        notificationAllowed = true,
        channelImportance = null,
        timezoneName = null,
        nextFireAt = null;

  final DiaryReminderSettings settings;
  final DiaryReminderIssue issue;

  /// 可以直接展示给用户的中文说明；为 null 表示无需额外提示。
  final String? message;

  /// 系统的待发通知列表里是否登记着本提醒。
  final bool scheduled;

  /// 是否具备精确闹钟能力。为 false 时排程会降级并可能延迟。
  final bool exactAllowed;

  /// 通知总开关是否打开。
  final bool notificationAllowed;

  /// 通知通道的重要性档位；null 表示通道尚不存在或读取失败。
  final int? channelImportance;

  /// 当前使用的时区名，例如 `Asia/Shanghai`；null 表示未就绪。
  final String? timezoneName;

  /// 下一次触发时刻（本地计算，仅用于展示与日志）。
  final DateTime? nextFireAt;

  bool get isHealthy => issue == DiaryReminderIssue.none;

  DiaryReminderStatus copyWith({
    DiaryReminderSettings? settings,
    DiaryReminderIssue? issue,
    String? message,
    bool? scheduled,
    bool? exactAllowed,
    bool? notificationAllowed,
    int? channelImportance,
    String? timezoneName,
    DateTime? nextFireAt,
  }) {
    return DiaryReminderStatus(
      settings: settings ?? this.settings,
      issue: issue ?? this.issue,
      message: message ?? this.message,
      scheduled: scheduled ?? this.scheduled,
      exactAllowed: exactAllowed ?? this.exactAllowed,
      notificationAllowed: notificationAllowed ?? this.notificationAllowed,
      channelImportance: channelImportance ?? this.channelImportance,
      timezoneName: timezoneName ?? this.timezoneName,
      nextFireAt: nextFireAt ?? this.nextFireAt,
    );
  }

  @override
  String toString() => 'DiaryReminderStatus(issue: ${issue.name}, '
      'scheduled: $scheduled, exact: $exactAllowed, '
      'notif: $notificationAllowed, tz: $timezoneName, '
      'next: $nextFireAt)';
}
