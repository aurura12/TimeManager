import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/siliconflow_config.dart';

class SiliconFlowAiService {
  static const _maxAttempts = 2;
  static const _requestTimeout = Duration(seconds: 90);

  static bool lastCallTimedOut = false;

  static String? get _apiKey {
    final key = SiliconFlowConfig.apiKey.trim();
    return key.isEmpty ? null : key;
  }

  static bool get hasApiKeyConfigured => _apiKey != null;

  /// 判断文本是否像模型思考链/草稿，而非最终复盘正文
  static bool looksLikeThinkingProcess(String text) {
    final lower = text.toLowerCase();
    const markers = [
      'analyze the request',
      'extract key information',
      'drafting the summary',
      'thinking process',
      'attempt 1',
      'attempt 2',
      'critique 1',
      'critique 2',
      '**draft',
      'redacted_thinking',
    ];
    for (final marker in markers) {
      if (lower.contains(marker)) return true;
    }

    final chineseCount =
        RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    if (text.length > 120 && chineseCount < 20) return true;
    return false;
  }

  /// 根据当日记录数据生成复盘文案；未配置 Key 或请求失败时返回 null
  static Future<String?> generateDailyReview({
    required String userPrompt,
  }) async {
    final apiKey = _apiKey;
    if (apiKey == null) return null;

    lastCallTimedOut = false;
    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
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
                        '你是时间管理 App 的每日复盘助手。根据用户的时间记录数据，用亲切的中文总结这一天发生的所有事件，最后给出改进建议。只输出最终总结正文。禁止输出思考过程、英文分析、草稿、标题、列表，不要自称 AI。',
                  },
                  {'role': 'user', 'content': userPrompt},
                ],
                'max_tokens': 512,
                'temperature': 0.6,
                'chat_template_kwargs': {'enable_thinking': false},
              }),
            )
            .timeout(_requestTimeout);

        if (response.statusCode != 200) {
          debugPrint(
            '硅基流动 API 错误(第$attempt次): ${response.statusCode} ${response.body}',
          );
          lastError = 'http_${response.statusCode}';
          continue;
        }

        final decoded = json.decode(response.body) as Map<String, dynamic>;
        final choices = decoded['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) {
          lastError = 'empty_choices';
          continue;
        }

        final message = choices.first['message'] as Map<String, dynamic>?;
        final content = _extractFinalAnswer(message);
        if (content == null) {
          debugPrint(
            '硅基流动无有效正文(第$attempt次): ${response.body.substring(0, response.body.length.clamp(0, 500))}',
          );
          lastError = 'empty_content';
          continue;
        }

        return content;
      } on TimeoutException catch (e) {
        lastError = e;
        debugPrint('硅基流动请求超时(第$attempt次): $e');
      } on SocketException catch (e) {
        lastError = e;
        debugPrint('硅基流动网络错误(第$attempt次): $e');
      } catch (e) {
        lastError = e;
        debugPrint('硅基流动请求失败(第$attempt次): $e');
      }
    }

    debugPrint('硅基流动最终失败: $lastError');
    lastCallTimedOut = lastError is TimeoutException;
    return null;
  }

  static String? _extractFinalAnswer(Map<String, dynamic>? message) {
    if (message == null) return null;

    final content = (message['content'] as String?)?.trim();
    if (content != null && content.isNotEmpty) {
      final sanitized = _sanitizeFinalAnswer(content);
      if (sanitized != null) return sanitized;
    }

    // 不把 reasoning_content 展示给用户；若只有思考链则视为失败并重试
    return null;
  }

  static String? _sanitizeFinalAnswer(String raw) {
    var text = raw.trim();

    text = text.replaceAll(
      RegExp(r'<\|im_start\|>think[\s\S]*?<\|im_end\|>', caseSensitive: false),
      '',
    );
    text = text.trim();
    if (text.isEmpty) return null;

    final extracted = _extractChineseSummary(text);
    if (extracted != null) return extracted;

    if (looksLikeThinkingProcess(text)) return null;

    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 从混杂草稿中提取最后一段中文总结
  static String? _extractChineseSummary(String text) {
    if (!looksLikeThinkingProcess(text)) {
      final chineseOnly = text
          .split('\n')
          .map((line) => line.trim())
          .where((line) =>
              line.isNotEmpty &&
              RegExp(r'[\u4e00-\u9fff]').hasMatch(line) &&
              !line.startsWith('**') &&
              !line.startsWith('*'))
          .toList();
      if (chineseOnly.isNotEmpty) {
        final candidate = chineseOnly.last;
        if (candidate.length >= 12 && candidate.length <= 160) {
          return candidate;
        }
      }
      return null;
    }

    final attemptMatches = RegExp(
      r'Attempt\s*\d+\s*:\s*["“]?([\u4e00-\u9fff，。！？、；：""''（）\s\d\.h小时分钟]+)',
      caseSensitive: false,
    ).allMatches(text);
    if (attemptMatches.isNotEmpty) {
      final last = attemptMatches.last.group(1)?.trim();
      if (last != null && last.length >= 12) {
        return last.replaceAll(RegExp(r'\s+'), ' ');
      }
    }

    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) =>
            l.isNotEmpty &&
            RegExp(r'[\u4e00-\u9fff]').hasMatch(l) &&
            !l.startsWith('**'))
        .toList();
    if (lines.isEmpty) return null;

    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (line.length >= 12 &&
          line.length <= 160 &&
          !looksLikeThinkingProcess(line)) {
        return line.replaceAll(RegExp(r'\s+'), ' ');
      }
    }
    return null;
  }
}
