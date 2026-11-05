/// 时间块到点提醒的设置与运行状态。
///
/// 这里只放纯数据：不引用任何通知插件的类型，方便单测与 UI 直接使用。
library;

import 'time_slot.dart';

/// 提醒设置：总开关 + 提前量（分钟）。
class TimeBlockReminderSettings {
  const TimeBlockReminderSettings({
    required this.enabled,
    required this.leadMinutes,
  });

  /// 未设置过时的默认值：关闭、提前 5 分钟。
  const TimeBlockReminderSettings.defaults()
      : enabled = false,
        leadMinutes = defaultLeadMinutes;

  static const int defaultLeadMinutes = 5;

  /// 自定义输入的上限。快捷档位已经覆盖 0–30，自定义只补非 5 的倍数。
  static const int maxLeadMinutes = 30;

  /// 快捷档位，0 展示为「准点」。
  static const List<int> quickLeadOptions = <int>[0, 5, 10, 15, 20, 25, 30];

  final bool enabled;
  final int leadMinutes;

  /// 展示用文案：「准点」/「提前 5 分钟」。
  String get leadLabel => leadMinutes == 0 ? '准点' : '提前 $leadMinutes 分钟';

  static bool isValidLead(int value) => value >= 0 && value <= maxLeadMinutes;

  TimeBlockReminderSettings copyWith({bool? enabled, int? leadMinutes}) {
    return TimeBlockReminderSettings(
      enabled: enabled ?? this.enabled,
      leadMinutes: leadMinutes ?? this.leadMinutes,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TimeBlockReminderSettings &&
      other.enabled == enabled &&
      other.leadMinutes == leadMinutes;

  @override
  int get hashCode => Object.hash(enabled, leadMinutes);

  @override
  String toString() =>
      'TimeBlockReminderSettings(enabled: $enabled, lead: $leadMinutes)';
}

/// 提醒当前处于什么问题状态。UI 只依据它决定展示什么。
enum TimeBlockReminderIssue {
  /// 一切正常。
  none,

  /// 非 Android：整个分区不展示。
  unsupportedPlatform,

  /// 尚未选择用户身份，开关必须先置灰。
  identityUnavailable,

  /// 读取设置本身失败。
  statusUnavailable,

  /// 系统时区不可用。绝不回退 UTC 排程，直接暂停。
  timezoneUnavailable,

  /// 通知权限未授予。
  notificationsDenied,

  /// 通知通道被用户关闭。
  channelDisabled,

  /// 没有精确闹钟能力，已降级为不精确排程，可能延迟。
  exactAlarmDenied,

  /// 排程调用失败。
  scheduleFailed,

  /// 写偏好失败，设置没有真正保存。
  saveFailed,

  /// 时间块数据尚未就绪（初始化 / 身份切换 / 远程视图），本轮保留现有排程。
  sourceUnavailable,
}

/// 提醒的完整状态快照。
class TimeBlockReminderStatus {
  const TimeBlockReminderStatus({
    required this.settings,
    this.issue = TimeBlockReminderIssue.none,
    this.message,
    this.scheduledCount = 0,
    this.nextFireAt,
    this.exactAllowed = false,
    this.notificationAllowed = true,
    this.channelImportance,
    this.timezoneName,
  });

  /// 读取设置失败时的安全兜底：抽屉必须能正常打开。
  const TimeBlockReminderStatus.fallback()
      : settings = const TimeBlockReminderSettings.defaults(),
        issue = TimeBlockReminderIssue.statusUnavailable,
        message = '读取提醒设置失败，请查看运行日志',
        scheduledCount = 0,
        nextFireAt = null,
        exactAllowed = false,
        notificationAllowed = true,
        channelImportance = null,
        timezoneName = null;

  final TimeBlockReminderSettings settings;
  final TimeBlockReminderIssue issue;

  /// 可以直接展示给用户的中文说明；为 null 表示无需额外提示。
  final String? message;

  /// 未来窗口内已登记的提醒条数。
  final int scheduledCount;

  /// 下一次触发时刻（本地计算，仅用于展示与日志）。
  final DateTime? nextFireAt;

  /// 是否具备精确闹钟能力。为 false 时排程会降级并可能延迟。
  final bool exactAllowed;

  /// 通知总开关是否打开。
  final bool notificationAllowed;

  /// 通知通道的重要性档位；null 表示通道尚不存在或读取失败。
  final int? channelImportance;

  /// 当前使用的时区名，例如 Asia/Shanghai；null 表示未就绪。
  final String? timezoneName;

  bool get isHealthy => issue == TimeBlockReminderIssue.none;

  TimeBlockReminderStatus copyWith({
    TimeBlockReminderSettings? settings,
    TimeBlockReminderIssue? issue,
    String? message,
    int? scheduledCount,
    DateTime? nextFireAt,
    bool? exactAllowed,
    bool? notificationAllowed,
    int? channelImportance,
    String? timezoneName,
  }) {
    return TimeBlockReminderStatus(
      settings: settings ?? this.settings,
      issue: issue ?? this.issue,
      message: message ?? this.message,
      scheduledCount: scheduledCount ?? this.scheduledCount,
      nextFireAt: nextFireAt ?? this.nextFireAt,
      exactAllowed: exactAllowed ?? this.exactAllowed,
      notificationAllowed: notificationAllowed ?? this.notificationAllowed,
      channelImportance: channelImportance ?? this.channelImportance,
      timezoneName: timezoneName ?? this.timezoneName,
    );
  }

  @override
  String toString() => 'TimeBlockReminderStatus(issue: $issue, '
      'scheduled: $scheduledCount, exact: $exactAllowed, '
      'notif: $notificationAllowed, tz: $timezoneName, '
      'next: $nextFireAt)';
}

/// 一天的时间块快照。服务据此生成提醒计划，不直接依赖 TimeProvider。
class TimeBlockReminderDay {
  const TimeBlockReminderDay({required this.date, required this.slots});

  /// 本地自然日 00:00。
  final DateTime date;

  /// 当天 144 个槽位；未加载的日期给空列表。
  final List<TimeSlot> slots;
}

/// 点击通知后要跳转的目标：哪一天的哪个块。
class TimeBlockReminderTap {
  const TimeBlockReminderTap({
    required this.dateKey,
    required this.startIndex,
  });

  static const String payloadPrefix = 'time_block_reminder:';

  final String dateKey;
  final int startIndex;

  /// 解析 time_block_reminder:2026-11-05:84。格式不对一律返回 null。
  static TimeBlockReminderTap? tryParse(String? payload) {
    if (payload == null || !payload.startsWith(payloadPrefix)) return null;
    final parts = payload.substring(payloadPrefix.length).split(':');
    if (parts.length != 2) return null;
    final dateKey = parts[0];
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(dateKey);
    if (match == null) return null;
    // DateTime.parse 会把 2026-13-05 归一化成 2027-01-05，必须逐段核对。
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    final startIndex = int.tryParse(parts[1]);
    if (startIndex == null || startIndex < 0 || startIndex > 143) return null;
    return TimeBlockReminderTap(dateKey: dateKey, startIndex: startIndex);
  }

  /// 解析失败的日期返回 null。
  DateTime? get date {
    final parsed = DateTime.tryParse(dateKey);
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }
}

/// 去重记录：某个块的这一次「应该响」已经被处理过。
///
/// 事件到点时 Dart 不运行，无法事后判断是否真的响过，所以只能在排程/补发
/// 的同时把记录写进去，避免每次回前台都重复补提醒。
class TimeBlockReminderFiredRecord {
  const TimeBlockReminderFiredRecord({
    required this.signature,
    required this.fireAtEpochMs,
    required this.catchUp,
  });

  final String signature;
  final int fireAtEpochMs;
  final bool catchUp;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sig': signature,
        'fireAt': fireAtEpochMs,
        'catchUp': catchUp,
      };

  static TimeBlockReminderFiredRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final signature = raw['sig'];
    final fireAt = raw['fireAt'];
    if (signature is! String || fireAt is! int) return null;
    return TimeBlockReminderFiredRecord(
      signature: signature,
      fireAtEpochMs: fireAt,
      catchUp: raw['catchUp'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TimeBlockReminderFiredRecord &&
      other.signature == signature &&
      other.fireAtEpochMs == fireAtEpochMs &&
      other.catchUp == catchUp;

  @override
  int get hashCode => Object.hash(signature, fireAtEpochMs, catchUp);
}
