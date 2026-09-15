import 'known_google_users.dart';

/// 打卡数据使用的逻辑身份匹配规则。
///
/// 手动身份的 id 是 `manual-g` / `manual-j`，Google 身份的 id 是 Google
/// subject；两者的 id 天然不同，但已知用户的邮箱代表同一个逻辑人。因此所有
/// 查询都应同时传入 id 和 email，先保留 id 精确匹配，再用规范化邮箱完成跨模式
/// 匹配。
class CheckInIdentity {
  CheckInIdentity._();

  static String normalizeEmail(String? email) {
    return KnownGoogleUsers.normalizeEmail(email ?? '');
  }

  static String? logicalKey({String? userId, String? email}) {
    final normalizedEmail = normalizeEmail(email);
    if (normalizedEmail.isNotEmpty) return 'email:$normalizedEmail';

    final normalizedId = userId?.trim() ?? '';
    if (normalizedId == 'manual-g') {
      return 'email:${KnownGoogleUsers.guaiGuaiEmail}';
    }
    if (normalizedId == 'manual-j') {
      return 'email:${KnownGoogleUsers.jingJingEmail}';
    }
    if (normalizedId.isNotEmpty) return 'id:$normalizedId';
    return null;
  }

  static bool matches({
    required String candidateId,
    required String candidateEmail,
    required String? userId,
    required String? email,
  }) {
    if (userId != null && userId.isNotEmpty && candidateId == userId) {
      return true;
    }

    final candidateNormalizedEmail = normalizeEmail(candidateEmail);
    final requestedNormalizedEmail = normalizeEmail(email);
    if (requestedNormalizedEmail.isNotEmpty &&
        candidateNormalizedEmail == requestedNormalizedEmail) {
      return true;
    }

    final candidateKey = logicalKey(
      userId: candidateId,
      email: candidateEmail,
    );
    final requestedKey = logicalKey(userId: userId, email: email);
    return candidateKey != null && candidateKey == requestedKey;
  }
}

/// 单次打卡记录
class CheckInRecord {
  const CheckInRecord({
    required this.id,
    required this.goalId,
    required this.userId,
    required this.userEmail,
    this.userDisplayName,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.locationName,
    this.photoPath,
    this.note,
    this.isBackfill = false,
  });

  final String id;
  final String goalId;
  final String userId;
  final String userEmail;
  final String? userDisplayName;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? locationName;

  /// GitHub 仓库内路径，如 images/乖乖/{recordId}.jpg
  final String? photoPath;
  final String? note;

  /// 是否为补打卡记录
  final bool isBackfill;

  bool get hasLocation => latitude != null && longitude != null;

  /// 是否属于指定用户：按 id 或 email 双通道匹配（兼容 Windows 手动身份与安卓 Google sub id）
  bool belongsTo(String userId, String email) => CheckInIdentity.matches(
        candidateId: this.userId,
        candidateEmail: userEmail,
        userId: userId,
        email: email,
      );

  String get userLabel => KnownGoogleUsers.displayLabel(
        email: userEmail,
        googleDisplayName: userDisplayName,
      );

  CheckInRecord copyWith({
    String? id,
    String? goalId,
    String? userId,
    String? userEmail,
    String? userDisplayName,
    DateTime? timestamp,
    double? latitude,
    double? longitude,
    String? locationName,
    String? photoPath,
    String? note,
    bool? isBackfill,
  }) {
    return CheckInRecord(
      id: id ?? this.id,
      goalId: goalId ?? this.goalId,
      userId: userId ?? this.userId,
      userEmail: userEmail ?? this.userEmail,
      userDisplayName: userDisplayName ?? this.userDisplayName,
      timestamp: timestamp ?? this.timestamp,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      photoPath: photoPath ?? this.photoPath,
      note: note ?? this.note,
      isBackfill: isBackfill ?? this.isBackfill,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'goal_id': goalId,
      'user_id': userId,
      'user_email': userEmail,
      if (userDisplayName != null) 'user_display_name': userDisplayName,
      'timestamp': timestamp.toIso8601String(),
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (locationName != null) 'location_name': locationName,
      if (photoPath != null) 'photo_path': photoPath,
      if (note != null && note!.isNotEmpty) 'note': note,
      if (isBackfill) 'is_backfill': true,
    };
  }

  factory CheckInRecord.fromJson(Map<String, dynamic> json) {
    final ts = DateTime.tryParse(json['timestamp']?.toString() ?? '');
    if (ts == null) {
      throw const FormatException('打卡记录 timestamp 无效');
    }
    return CheckInRecord(
      id: json['id']?.toString() ?? '',
      goalId: json['goal_id']?.toString() ?? '',
      userId: json['user_id']?.toString() ?? '',
      userEmail: json['user_email']?.toString() ?? '',
      userDisplayName: json['user_display_name']?.toString(),
      timestamp: ts,
      latitude: _toDouble(json['latitude']),
      longitude: _toDouble(json['longitude']),
      locationName: json['location_name']?.toString(),
      photoPath: json['photo_path']?.toString(),
      note: json['note']?.toString(),
      isBackfill: json['is_backfill'] == true,
    );
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
