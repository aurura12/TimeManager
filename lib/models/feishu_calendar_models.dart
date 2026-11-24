/// 飞书日历同步的纯数据对象，不依赖 UI 与网络。
library;

/// 已经在本地合并好的一个时间块，准备写成飞书日程。
class FeishuEventDraft {
  const FeishuEventDraft({
    required this.summary,
    required this.start,
    required this.end,
  });

  final String summary;
  final DateTime start;
  final DateTime end;

  int get startSeconds => start.millisecondsSinceEpoch ~/ 1000;
  int get endSeconds => end.millisecondsSinceEpoch ~/ 1000;

  /// 用于和远端日程做差集的稳定签名。
  String get signature => '$summary|$startSeconds|$endSeconds';

  @override
  String toString() => 'FeishuEventDraft($summary, $startSeconds, $endSeconds)';
}

/// 飞书日历上已存在的日程（只保留差集需要的字段）。
class FeishuRemoteEvent {
  const FeishuRemoteEvent({
    required this.eventId,
    required this.summary,
    required this.startSeconds,
    required this.endSeconds,
  });

  final String eventId;
  final String summary;
  final int startSeconds;
  final int endSeconds;

  String get signature => '$summary|$startSeconds|$endSeconds';
}

/// 某一天需要对飞书做的增删操作。
class FeishuDayDiff {
  const FeishuDayDiff({required this.toCreate, required this.toDelete});

  const FeishuDayDiff.empty()
      : toCreate = const [],
        toDelete = const [];

  final List<FeishuEventDraft> toCreate;
  final List<FeishuRemoteEvent> toDelete;

  bool get isEmpty => toCreate.isEmpty && toDelete.isEmpty;

  @override
  String toString() =>
      'FeishuDayDiff(create: ${toCreate.length}, delete: ${toDelete.length})';
}

/// 一次授权换回来的令牌集合。
class FeishuTokenSet {
  const FeishuTokenSet({
    required this.accessToken,
    required this.accessExpiresAt,
    this.refreshToken,
    this.refreshExpiresAt,
    this.scope,
  });

  final String accessToken;
  final DateTime accessExpiresAt;
  final String? refreshToken;
  final DateTime? refreshExpiresAt;
  final String? scope;

  bool get hasRefreshToken => (refreshToken ?? '').isNotEmpty;

  /// 提前 [skew] 判定过期，避免请求途中刚好失效。
  bool isAccessExpired(DateTime now,
      {Duration skew = const Duration(minutes: 5)}) {
    return !now.isBefore(accessExpiresAt.subtract(skew));
  }

  bool isRefreshExpired(DateTime now) {
    final expiresAt = refreshExpiresAt;
    return expiresAt != null && !now.isBefore(expiresAt);
  }
}

/// 用户填写的飞书自建应用凭据。
class FeishuCredentials {
  const FeishuCredentials({required this.appId, required this.appSecret});

  final String appId;
  final String appSecret;

  bool get isComplete => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;
}

/// 回环服务器 / 粘贴解析出来的授权回调结果。
class FeishuAuthCallback {
  const FeishuAuthCallback(
      {this.code, this.state, this.error, this.description});

  final String? code;
  final String? state;
  final String? error;
  final String? description;

  bool get isSuccess => (code ?? '').isNotEmpty && (error ?? '').isEmpty;
}

/// 设置页展示的连接状态。
enum FeishuConnectionStatus {
  /// 还没填 App ID / Secret
  notConfigured,

  /// 有凭据但没授权，或授权已失效需要重新授权
  needsAuth,

  /// 已拿到可用令牌
  connected,

  /// 当前还没选择身份（乖乖/晶晶）
  noIdentity,
}

/// 同步一天的结果。
class FeishuDaySyncOutcome {
  const FeishuDaySyncOutcome({
    required this.dateKey,
    required this.success,
    this.created = 0,
    this.deleted = 0,
    this.message,
    this.needReauth = false,
  });

  final String dateKey;
  final bool success;
  final int created;
  final int deleted;
  final String? message;
  final bool needReauth;

  static FeishuDaySyncOutcome failed(
    String dateKey,
    String message, {
    bool needReauth = false,
  }) {
    return FeishuDaySyncOutcome(
      dateKey: dateKey,
      success: false,
      message: message,
      needReauth: needReauth,
    );
  }
}

/// 授权流程中途需要跨进程记住的参数（手机端回环可能收不到回调）。
class FeishuPendingAuth {
  const FeishuPendingAuth({
    required this.state,
    required this.codeVerifier,
    required this.createdAt,
  });

  final String state;
  final String codeVerifier;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'state': state,
        'code_verifier': codeVerifier,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  static FeishuPendingAuth? fromJson(Map<String, dynamic> json) {
    final state = json['state']?.toString();
    final verifier = json['code_verifier']?.toString();
    final createdAt = json['created_at'];
    if (state == null || verifier == null || createdAt is! int) return null;
    return FeishuPendingAuth(
      state: state,
      codeVerifier: verifier,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
    );
  }
}

/// 一次授权的结果。
class FeishuAuthResult {
  const FeishuAuthResult({required this.success, this.message});

  const FeishuAuthResult.ok()
      : success = true,
        message = null;

  const FeishuAuthResult.failed(this.message) : success = false;

  final bool success;
  final String? message;
}

/// 飞书 OpenAPI 调用结果；业务错误不抛异常。
class FeishuApiResult<T> {
  const FeishuApiResult._({
    required this.success,
    this.data,
    this.error,
    this.unauthorized = false,
  });

  factory FeishuApiResult.ok(T data) =>
      FeishuApiResult._(success: true, data: data);

  factory FeishuApiResult.failed(
    String error, {
    bool unauthorized = false,
  }) =>
      FeishuApiResult._(
        success: false,
        error: error,
        unauthorized: unauthorized,
      );

  final bool success;
  final T? data;
  final String? error;

  /// 令牌失效，调用方应刷新后重试一次。
  final bool unauthorized;
}

/// 某一天的事件列表（带截断标记）。
class FeishuEventPage {
  const FeishuEventPage({required this.events, required this.truncated});

  final List<FeishuRemoteEvent> events;

  /// 飞书列表接口用 start_time/end_time 时无法分页，读不完就算截断。
  final bool truncated;
}

/// 一次多日同步的汇总。
class FeishuSyncSummary {
  const FeishuSyncSummary({
    required this.totalDays,
    required this.successDays,
    required this.created,
    required this.deleted,
    required this.failedDates,
    this.needReauth = false,
    this.cancelled = false,
    this.message,
  });

  final int totalDays;
  final int successDays;
  final int created;
  final int deleted;
  final List<String> failedDates;
  final bool needReauth;
  final bool cancelled;
  final String? message;

  int get failedDays => failedDates.length;

  String describe() {
    if (cancelled) return '已取消（成功 $successDays / $totalDays 天）';
    if (failedDates.isEmpty) {
      return '完成：$successDays 天，新增 $created 条，删除 $deleted 条';
    }
    return '完成：成功 $successDays 天，失败 ${failedDates.length} 天';
  }
}

/// 同步到 Gitee 仓库里的授权信息（凭据 + 令牌），供同一身份的其它设备复用。
class FeishuRemoteAuth {
  const FeishuRemoteAuth({
    required this.updatedAt,
    this.credentials,
    this.tokens,
    this.revoked = false,
    this.sha,
  });

  final DateTime updatedAt;
  final FeishuCredentials? credentials;
  final FeishuTokenSet? tokens;

  /// 用户主动断开时写入的墓碑，避免另一台设备又把授权同步回来。
  final bool revoked;

  final String? sha;

  bool get hasAuth => !revoked && credentials != null;

  FeishuRemoteAuth withSha(String? sha) => FeishuRemoteAuth(
        updatedAt: updatedAt,
        credentials: credentials,
        tokens: tokens,
        revoked: revoked,
        sha: sha,
      );

  Map<String, dynamic> toJson() {
    final credentials = this.credentials;
    final tokens = this.tokens;
    return {
      'revoked': revoked,
      'updated_at': updatedAt.millisecondsSinceEpoch,
      if (credentials != null) 'app_id': credentials.appId,
      if (credentials != null) 'app_secret': credentials.appSecret,
      if (tokens != null) 'access_token': tokens.accessToken,
      if (tokens != null)
        'access_expires_at': tokens.accessExpiresAt.millisecondsSinceEpoch,
      if (tokens?.hasRefreshToken ?? false)
        'refresh_token': tokens!.refreshToken,
      if (tokens?.refreshExpiresAt != null)
        'refresh_expires_at': tokens!.refreshExpiresAt!.millisecondsSinceEpoch,
      if ((tokens?.scope ?? '').isNotEmpty) 'scope': tokens!.scope,
    };
  }

  static FeishuRemoteAuth? fromJson(Map<String, dynamic> json, {String? sha}) {
    final updatedAt = json['updated_at'];
    if (updatedAt is! int) return null;
    final appId = (json['app_id'] ?? '').toString().trim();
    final appSecret = (json['app_secret'] ?? '').toString().trim();
    final credentials = appId.isEmpty || appSecret.isEmpty
        ? null
        : FeishuCredentials(appId: appId, appSecret: appSecret);

    final accessToken = (json['access_token'] ?? '').toString().trim();
    final accessExpiresAt = json['access_expires_at'];
    FeishuTokenSet? tokens;
    if (accessToken.isNotEmpty && accessExpiresAt is int) {
      final refreshExpiresAt = json['refresh_expires_at'];
      final refreshToken =
          (json['refresh_token'] ?? '').toString().trim().isEmpty
              ? null
              : json['refresh_token'].toString().trim();
      tokens = FeishuTokenSet(
        accessToken: accessToken,
        accessExpiresAt: DateTime.fromMillisecondsSinceEpoch(accessExpiresAt),
        refreshToken: refreshToken,
        refreshExpiresAt: refreshExpiresAt is int
            ? DateTime.fromMillisecondsSinceEpoch(refreshExpiresAt)
            : null,
        scope: (json['scope'] ?? '').toString().isEmpty
            ? null
            : json['scope'].toString(),
      );
    }

    return FeishuRemoteAuth(
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt),
      credentials: credentials,
      tokens: tokens,
      revoked: json['revoked'] == true,
      sha: sha,
    );
  }
}
