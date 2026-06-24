class DailyReviewChatMessage {
  final String role;
  final String content;
  final int createdAt;
  final bool fromReview;
  final bool contextSync;

  const DailyReviewChatMessage({
    required this.role,
    required this.content,
    required this.createdAt,
    this.fromReview = false,
    this.contextSync = false,
  });

  bool get isUser => role == 'user';

  /// 仅用于 UI 展示，不参与 API 多轮上下文（避免过时复盘干扰）
  bool get includeInApiHistory => !fromReview;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'createdAt': createdAt,
        if (fromReview) 'fromReview': true,
        if (contextSync) 'contextSync': true,
      };

  factory DailyReviewChatMessage.fromJson(Map<String, dynamic> json) {
    return DailyReviewChatMessage(
      role: json['role'] as String,
      content: json['content'] as String,
      createdAt: json['createdAt'] as int,
      fromReview: json['fromReview'] == true,
      contextSync: json['contextSync'] == true,
    );
  }

  DailyReviewChatMessage copyWith({
    String? role,
    String? content,
    int? createdAt,
    bool? fromReview,
    bool? contextSync,
  }) {
    return DailyReviewChatMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      fromReview: fromReview ?? this.fromReview,
      contextSync: contextSync ?? this.contextSync,
    );
  }
}
