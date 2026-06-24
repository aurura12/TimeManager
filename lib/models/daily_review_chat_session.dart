import 'daily_review_chat_message.dart';

class DailyReviewChatSession {
  final List<DailyReviewChatMessage> messages;
  final String? dataHash;

  const DailyReviewChatSession({
    this.messages = const [],
    this.dataHash,
  });
}
