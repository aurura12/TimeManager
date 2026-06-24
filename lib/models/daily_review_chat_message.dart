class DailyReviewChatMessage {
  final String role;
  final String content;
  final int createdAt;
  final bool fromReview;

  const DailyReviewChatMessage({
    required this.role,
    required this.content,
    required this.createdAt,
    this.fromReview = false,
  });

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'createdAt': createdAt,
        if (fromReview) 'fromReview': true,
      };

  factory DailyReviewChatMessage.fromJson(Map<String, dynamic> json) {
    return DailyReviewChatMessage(
      role: json['role'] as String,
      content: json['content'] as String,
      createdAt: json['createdAt'] as int,
      fromReview: json['fromReview'] == true,
    );
  }

  DailyReviewChatMessage copyWith({
    String? role,
    String? content,
    int? createdAt,
    bool? fromReview,
  }) {
    return DailyReviewChatMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      fromReview: fromReview ?? this.fromReview,
    );
  }
}
