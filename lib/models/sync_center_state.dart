/// 同步中心支持的数据模块。
enum SyncModule {
  schedule,
  categories,
  targets,
  diary,
  travel,
  checkIn,
  googleCalendar,
}

extension SyncModuleX on SyncModule {
  String get label => switch (this) {
        SyncModule.schedule => '日程',
        SyncModule.categories => '分类',
        SyncModule.targets => '目标',
        SyncModule.diary => '日记',
        SyncModule.travel => '出行',
        SyncModule.checkIn => '打卡',
        SyncModule.googleCalendar => 'Google 日历',
      };

  String get storageKey => name;
}

/// 同步中心保留的最后一次状态。
enum SyncModuleStatus {
  idle,
  syncing,
  success,
  pending,
  offline,
  failed,
  conflict,
  disabled,
  busy,
}

extension SyncModuleStatusX on SyncModuleStatus {
  String get label => switch (this) {
        // idle 只表示“没有任何可靠同步记录”，不是“同步失败”。首次安装
        // 或刚切换身份时都应显示为尚未检查，避免误导成未同步。
        SyncModuleStatus.idle => '尚未检查',
        SyncModuleStatus.syncing => '同步中',
        SyncModuleStatus.success => '已同步',
        SyncModuleStatus.pending => '待同步',
        SyncModuleStatus.offline => '离线待恢复',
        SyncModuleStatus.failed => '同步失败',
        SyncModuleStatus.conflict => '有冲突',
        SyncModuleStatus.disabled => '已关闭',
        SyncModuleStatus.busy => '已有任务进行中',
      };
}

/// 单个数据模块在同步中心中的可持久化状态。
class SyncModuleState {
  const SyncModuleState({
    required this.module,
    this.enabled = true,
    this.status = SyncModuleStatus.idle,
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.pendingUploadCount = 0,
    this.pendingDownloadCount = 0,
    this.failureCount = 0,
    this.conflictCount = 0,
    this.message,
    this.source,
    this.scope,
    this.details = const <String>[],
  });

  final SyncModule module;
  final bool enabled;
  final SyncModuleStatus status;

  /// 最近一次同步尝试的时间（成功、失败、离线都算尝试）。
  final DateTime? lastAttemptAt;

  /// 最近一次真正成功的时间。失败时必须保留上一次的成功时间。
  final DateTime? lastSuccessAt;

  final int pendingUploadCount;
  final int pendingDownloadCount;
  final int failureCount;
  final int conflictCount;
  final String? message;

  /// 状态的来源，例如「同步中心」「日程页」「后台自动同步」。
  final String? source;

  /// 同步范围，例如某一天或全部日程。
  final String? scope;

  final List<String> details;

  bool get hasPending => pendingUploadCount > 0 || pendingDownloadCount > 0;
  bool get hasIssue =>
      status == SyncModuleStatus.offline ||
      status == SyncModuleStatus.failed ||
      status == SyncModuleStatus.conflict;

  static const Object _unset = Object();

  SyncModuleState copyWith({
    bool? enabled,
    SyncModuleStatus? status,
    Object? lastAttemptAt = _unset,
    Object? lastSuccessAt = _unset,
    int? pendingUploadCount,
    int? pendingDownloadCount,
    int? failureCount,
    int? conflictCount,
    Object? message = _unset,
    Object? source = _unset,
    Object? scope = _unset,
    List<String>? details,
  }) {
    return SyncModuleState(
      module: module,
      enabled: enabled ?? this.enabled,
      status: status ?? this.status,
      lastAttemptAt: identical(lastAttemptAt, _unset)
          ? this.lastAttemptAt
          : lastAttemptAt as DateTime?,
      lastSuccessAt: identical(lastSuccessAt, _unset)
          ? this.lastSuccessAt
          : lastSuccessAt as DateTime?,
      pendingUploadCount: pendingUploadCount ?? this.pendingUploadCount,
      pendingDownloadCount: pendingDownloadCount ?? this.pendingDownloadCount,
      failureCount: failureCount ?? this.failureCount,
      conflictCount: conflictCount ?? this.conflictCount,
      message: identical(message, _unset) ? this.message : message as String?,
      source: identical(source, _unset) ? this.source : source as String?,
      scope: identical(scope, _unset) ? this.scope : scope as String?,
      details: details ?? this.details,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'status': status.name,
        'lastAttemptAt': lastAttemptAt?.toIso8601String(),
        'lastSuccessAt': lastSuccessAt?.toIso8601String(),
        'pendingUploadCount': pendingUploadCount,
        'pendingDownloadCount': pendingDownloadCount,
        'failureCount': failureCount,
        'conflictCount': conflictCount,
        'message': message,
        'source': source,
        'scope': scope,
        'details': details,
      };

  factory SyncModuleState.fromJson(
    SyncModule module,
    Map<String, dynamic> json,
  ) {
    final rawStatus = json['status']?.toString();
    final status = SyncModuleStatus.values.firstWhere(
      (value) => value.name == rawStatus,
      orElse: () => SyncModuleStatus.idle,
    );
    final rawDetails = json['details'];
    return SyncModuleState(
      module: module,
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      status: status,
      lastAttemptAt: DateTime.tryParse(json['lastAttemptAt']?.toString() ?? ''),
      // v1 只保存了 lastSyncAt，且当时它同时代表尝试和成功。迁移时按成功
      // 时间读取，让老用户的“最后成功”时间不丢失。
      lastSuccessAt: DateTime.tryParse(
            json['lastSuccessAt']?.toString() ??
                json['lastSyncAt']?.toString() ??
                '',
          ),
      pendingUploadCount: _nonNegativeInt(json['pendingUploadCount']),
      pendingDownloadCount: _nonNegativeInt(json['pendingDownloadCount']),
      failureCount: _nonNegativeInt(json['failureCount']),
      conflictCount: _nonNegativeInt(json['conflictCount']),
      message: _optionalString(json['message']),
      source: _optionalString(json['source']),
      scope: _optionalString(json['scope']),
      details: rawDetails is List
          ? rawDetails.whereType<String>().take(10).toList(growable: false)
          : const <String>[],
    );
  }

  static int _nonNegativeInt(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed == null || parsed < 0 ? 0 : parsed;
  }

  static String? _optionalString(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}

/// 同步入口的统一返回值。业务 service 仍保留自己的详细结果，编排层只
/// 把用户需要在同步中心看到的结果归一化。
class SyncOperationResult {
  const SyncOperationResult({
    required this.status,
    this.message,
    this.pendingUploadCount = 0,
    this.pendingDownloadCount = 0,
    this.conflictCount = 0,
    this.details = const <String>[],
  });

  final SyncModuleStatus status;
  final String? message;
  final int pendingUploadCount;
  final int pendingDownloadCount;
  final int conflictCount;
  final List<String> details;

  bool get succeeded => status == SyncModuleStatus.success;

  const SyncOperationResult.success({
    String? message,
    int pendingUploadCount = 0,
    int pendingDownloadCount = 0,
  }) : this(
          status: SyncModuleStatus.success,
          message: message,
          pendingUploadCount: pendingUploadCount,
          pendingDownloadCount: pendingDownloadCount,
        );

  const SyncOperationResult.offline(
    String message, {
    int pendingUploadCount = 0,
    int pendingDownloadCount = 0,
  }) : this(
          status: SyncModuleStatus.offline,
          message: message,
          pendingUploadCount: pendingUploadCount,
          pendingDownloadCount: pendingDownloadCount,
        );

  const SyncOperationResult.failed(
    String message, {
    int pendingUploadCount = 0,
    int pendingDownloadCount = 0,
  }) : this(
          status: SyncModuleStatus.failed,
          message: message,
          pendingUploadCount: pendingUploadCount,
          pendingDownloadCount: pendingDownloadCount,
        );

  const SyncOperationResult.conflict(
    String message, {
    int conflictCount = 1,
    List<String> details = const <String>[],
  }) : this(
          status: SyncModuleStatus.conflict,
          message: message,
          conflictCount: conflictCount,
          details: details,
        );

  const SyncOperationResult.busy(String message)
      : this(status: SyncModuleStatus.busy, message: message);

  const SyncOperationResult.disabled(String message)
      : this(status: SyncModuleStatus.disabled, message: message);
}
