import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/siliconflow_config.dart';

class SiliconFlowAiService {
  static String? get _apiKey {
    final key = SiliconFlowConfig.apiKey.trim();
    return key.isEmpty ? null : key;
  }

  static bool get hasApiKeyConfigured => _apiKey != null;

  /// 根据当日记录数据生成复盘文案；未配置 Key 或请求失败时返回 null
  static Future<String?> generateDailyReview({
    required String userPrompt,
  }) async {
    final apiKey = _apiKey;
    if (apiKey == null) return null;

    try {
      final response = await http
          .post(
            Uri.parse(SiliconFlowConfig.baseUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': SiliconFlowConfig.model,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      '你是时间管理 App 的每日复盘助手。根据用户的时间记录数据，用简洁亲切的中文总结「这一天过得怎么样」。'
                      '直接输出总结正文，2-4句话，不超过120字，不要用列表或标题，不要自称 AI。',
                },
                {'role': 'user', 'content': userPrompt},
              ],
              'max_tokens': 256,
              'temperature': 0.7,
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode != 200) {
        debugPrint('硅基流动 API 错误: ${response.statusCode} ${response.body}');
        return null;
      }

      final decoded = json.decode(response.body) as Map<String, dynamic>;
      final choices = decoded['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return null;

      final message = choices.first['message'] as Map<String, dynamic>?;
      final content = message?['content'] as String?;
      if (content == null || content.trim().isEmpty) return null;

      return content.trim().replaceAll(RegExp(r'\s+'), ' ');
    } catch (e) {
      debugPrint('硅基流动请求失败: $e');
      return null;
    }
  }
}
