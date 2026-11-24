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
