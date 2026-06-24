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

    final chineseCount = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    if (text.length > 120 && chineseCount < 20) return true;
    return false;
  }

  /// 多轮对话；messages 需含 system / user / assistant
  static Future<String?> chat({
    required List<Map<String, String>> messages,
  }) async {
    final apiKey = _apiKey;
    if (apiKey == null) return null;

    lastCallTimedOut = false;
    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final response = await http
            .post(
              Uri.parse(SiliconFlowConfig.chatCompletionsUrl),
              headers: {
                'Content-Type': 'application/json',
                'api-key': apiKey,
              },
              body: jsonEncode({
                'model': SiliconFlowConfig.model,
                'messages': messages,
                'max_completion_tokens': 512,
                'thinking': {'type': 'disabled'},
              }),
            )
            .timeout(_requestTimeout);

        if (response.statusCode != 200) {
          debugPrint(
            'MiMo Chat 错误(第$attempt次): ${response.statusCode} ${response.body}',
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
          lastError = 'empty_content';
          continue;
        }
        return content;
      } on TimeoutException catch (e) {
        lastError = e;
        debugPrint('MiMo Chat 超时(第$attempt次): $e');
      } on SocketException catch (e) {
        lastError = e;
        debugPrint('MiMo Chat 网络错误(第$attempt次): $e');
      } catch (e) {
        lastError = e;
        debugPrint('MiMo Chat 失败(第$attempt次): $e');
      }
    }

    lastCallTimedOut = lastError is TimeoutException;
    return null;
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
              Uri.parse(SiliconFlowConfig.chatCompletionsUrl),
              headers: {
                'Content-Type': 'application/json',
                'api-key': apiKey,
              },
              body: jsonEncode({
                'model': SiliconFlowConfig.model,
                'messages': [
                  {
                    'role': 'system',
                    'content':
                        '你是时间管理 App 的每日复盘助手。根据用户数据写「短复盘」。\n'
                        '核心：先读懂事项名称——用户实际在做什么（如「编程」是写代码、「练琴」是练乐器、「通勤」是路上），用自然语言说出含义，不要只复读标签。\n'
                        '篇幅：全文 120～180 字，最多 2 个自然段，每段 2～3 句。\n'
                        '写法：\n'
                        '- 第 1 段：概括今天主要在忙什么、时间大致怎么分配；只点时长前 2 的事项，各带 1 个主要时段即可，禁止逐条念完整时间轴。\n'
                        '- 第 2 段：一句与昨日的具体变化（用数据里的数字或事项名）；若有空白时段或明显偏科，给 1 句短建议。\n'
                        '禁止：空话套话、编造未出现的事项、罗列全部时间段、超过 180 字、列表、自称 AI、英文。',
                  },
                  {'role': 'user', 'content': userPrompt},
                ],
                'max_completion_tokens': 384,
                'thinking': {'type': 'disabled'},
              }),
            )
            .timeout(_requestTimeout);

        if (response.statusCode != 200) {
          debugPrint(
            'MiMo API 错误(第$attempt次): ${response.statusCode} ${response.body}',
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
            'MiMo API 无有效正文(第$attempt次): ${response.body.substring(0, response.body.length.clamp(0, 500))}',
          );
          lastError = 'empty_content';
          continue;
        }

        return content;
      } on TimeoutException catch (e) {
        lastError = e;
        debugPrint('MiMo 请求超时(第$attempt次): $e');
      } on SocketException catch (e) {
        lastError = e;
        debugPrint('MiMo 网络错误(第$attempt次): $e');
      } catch (e) {
        lastError = e;
        debugPrint('MiMo 请求失败(第$attempt次): $e');
      }
    }

    debugPrint('MiMo 最终失败: $lastError');
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

    if (looksLikeThinkingProcess(text)) {
      final extracted = _extractChineseSummary(text);
      if (extracted != null) return extracted;
      return null;
    }

    // 保留段落换行，只压缩行内多余空格
    final lines = text.split('\n');
    final normalized = lines
        .map((line) => line.trim().replaceAll(RegExp(r'[ \t]+'), ' '))
        .where((line) => line.isNotEmpty)
        .join('\n')
        .trim();
    if (normalized.isEmpty) return null;

    final chineseCount =
        RegExp(r'[\u4e00-\u9fff]').allMatches(normalized).length;
    if (normalized.length >= 40 && chineseCount >= 20) {
      return normalized;
    }

    return normalized.length >= 12 ? normalized : null;
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
      r'Attempt\s*\d+\s*:\s*["“]?([\u4e00-\u9fff，。！？、；：""' '（）\s\d\.h小时分钟]+)',
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
