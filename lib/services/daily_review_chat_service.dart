import '../models/daily_review_chat_message.dart';
import 'daily_review_summary.dart';
import 'siliconflow_ai_service.dart';

enum DailyReviewChatError {
  noApiKey,
  networkFailed,
  timeout,
}

class DailyReviewChatReply {
  final String? content;
  final DailyReviewChatError? error;

  const DailyReviewChatReply({this.content, this.error});

  bool get isSuccess => content != null && content!.isNotEmpty;

  String get errorMessage {
    switch (error) {
      case DailyReviewChatError.noApiKey:
        return '未配置 AI API Key。';
      case DailyReviewChatError.networkFailed:
        return '发送失败，请检查网络后重试。';
      case DailyReviewChatError.timeout:
        return '响应超时，请稍后重试。';
      case null:
        return '未知错误';
    }
  }
}

class DailyReviewChatService {
  static const _maxHistoryTurns = 20;

  static const _systemPrompt =
      '你是时间管理 App 的每日复盘对话助手。用户正在查看某一天的时间记录并追问。\n'
      '你会收到【当日记录数据】和对话历史。\n'
      '规则：\n'
      '- 只根据当日数据回答，禁止编造未出现的事项。\n'
      '- 读懂事项名称的实际含义，用自然口语回答。\n'
      '- 每次 80～150 字，直接回答问题，不要复读整份时间轴。\n'
      '- 不要列表、不要自称 AI、不要英文。';

  static Future<DailyReviewChatReply> send({
    required DateTime date,
    required String userText,
    required List<DailyReviewChatMessage> history,
  }) async {
    if (!SiliconFlowAiService.hasApiKeyConfigured) {
      return const DailyReviewChatReply(error: DailyReviewChatError.noApiKey);
    }

    final trimmed = userText.trim();
    if (trimmed.isEmpty) {
      return const DailyReviewChatReply(error: DailyReviewChatError.networkFailed);
    }

    final dayContext = await DailyReviewSummaryBuilder.buildDayContext(date);
    final apiMessages = <Map<String, String>>[
      {
        'role': 'system',
        'content': '$_systemPrompt\n\n【当日记录数据】\n$dayContext',
      },
    ];

    final recent = history.length > _maxHistoryTurns
        ? history.sublist(history.length - _maxHistoryTurns)
        : history;
    for (final msg in recent) {
      apiMessages.add({'role': msg.role, 'content': msg.content});
    }
    apiMessages.add({'role': 'user', 'content': trimmed});

    final reply = await SiliconFlowAiService.chat(messages: apiMessages);
    if (reply == null || reply.isEmpty) {
      return DailyReviewChatReply(
        error: SiliconFlowAiService.lastCallTimedOut
            ? DailyReviewChatError.timeout
            : DailyReviewChatError.networkFailed,
      );
    }

    return DailyReviewChatReply(content: reply);
  }
}
