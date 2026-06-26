import 'known_google_users.dart';

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
  /// GitHub 仓库内路径，如 images/check_in/{userId}/{recordId}.jpg
  final String? photoPath;
  final String? note;

  bool get hasLocation => latitude != null && longitude != null;

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
    );
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
