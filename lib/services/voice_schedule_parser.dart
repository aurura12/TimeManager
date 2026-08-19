import '../models/category.dart';
import '../models/voice_schedule_draft.dart';

class VoiceScheduleParser {
  static final RegExp _clockPattern = RegExp(
    r'(?:(凌晨|早上|上午|中午|下午|晚上))?'
    r'([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})'
    r'(?:(?:点|时)(半|[0-9]{1,2}分?)?|[:：]([0-9]{1,2}))',
  );

  static final RegExp _durationPattern = RegExp(
    r'(半小时|(?:[零〇一二两三四五六七八九十百0-9]+)(?:个)?小时|'
    r'(?:[零〇一二两三四五六七八九十百0-9]+)分钟)',
  );

  static VoiceScheduleParseResult parse({
    required String transcript,
    required DateTime baseDate,
    required List<Category> categories,
  }) {
    final text = transcript.trim();
    if (text.isEmpty) {
      return const VoiceScheduleParseResult.failure('没有识别到语音内容');
    }

    final date = _parseDate(text, baseDate);
    final times = _parseTimes(text);
    if (times.isEmpty) {
      return const VoiceScheduleParseResult.failure('没有识别到开始时间');
    }

    final startMinutes = times.first.minutes;
    var endMinutes = times.length >= 2 ? times[1].minutes : null;
    if (endMinutes == null) {
      final duration = _parseDuration(text);
      if (duration == null) {
        return const VoiceScheduleParseResult.failure('请说清楚结束时间或持续时长');
      }
      endMinutes = startMinutes + duration;
    }

    if (endMinutes <= startMinutes) {
      return const VoiceScheduleParseResult.failure('结束时间必须晚于开始时间');
    }
    if (endMinutes > 24 * 60) {
      return const VoiceScheduleParseResult.failure('暂不支持跨天日程');
    }

    final event = _matchExistingEvent(text, categories);
    final label = event?.label ?? _extractTemporaryLabel(text);
    if (label == null || label.isEmpty) {
      return const VoiceScheduleParseResult.failure('没有识别到事项名称');
    }

    final startIndex = startMinutes ~/ 10;
    final endIndexExclusive = (endMinutes + 9) ~/ 10;
    if (startIndex < 0 || endIndexExclusive > 144) {
      return const VoiceScheduleParseResult.failure('日程时间超出当天范围');
    }

    return VoiceScheduleParseResult.success(
      VoiceScheduleDraft(
        date: date,
        startIndex: startIndex,
        endIndexExclusive: endIndexExclusive,
        label: label,
        categoryId: event?.categoryId,
        transcript: text,
        eventKind: event == null
            ? VoiceScheduleEventKind.temporary
            : VoiceScheduleEventKind.existing,
      ),
    );
  }

  static DateTime _parseDate(String text, DateTime baseDate) {
    final day = DateTime(baseDate.year, baseDate.month, baseDate.day);
    if (text.contains('大后天')) return day.add(const Duration(days: 3));
    if (text.contains('后天')) return day.add(const Duration(days: 2));
    if (text.contains('明天')) return day.add(const Duration(days: 1));

    final nextWeekday = RegExp(r'下周([一二三四五六日天1-7])').firstMatch(text);
    if (nextWeekday != null) {
      final target = _weekdayNumber(nextWeekday.group(1)!);
      var days = (target - day.weekday) % 7;
      if (days == 0) days = 7;
      return day.add(Duration(days: days));
    }
    return day;
  }

  static int _weekdayNumber(String value) {
    const map = {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '日': 7,
      '天': 7,
      '1': 1,
      '2': 2,
      '3': 3,
      '4': 4,
      '5': 5,
      '6': 6,
      '7': 7,
    };
    return map[value] ?? 1;
  }

  static List<_TimePoint> _parseTimes(String text) {
    final points = <_TimePoint>[];
    String? inheritedPeriod;
    for (final match in _clockPattern.allMatches(text)) {
      final hour = _parseNumber(match.group(2)!);
      if (hour == null || hour > 24) continue;
      final period = match.group(1) ?? inheritedPeriod;
      if (match.group(1) != null) inheritedPeriod = match.group(1);

      int minute;
      final minuteToken = match.group(3);
      final colonMinute = match.group(4);
      if (minuteToken == '半') {
        minute = 30;
      } else if (minuteToken != null && minuteToken.isNotEmpty) {
        minute = _parseNumber(minuteToken.replaceAll('分', '')) ?? 0;
      } else if (colonMinute != null) {
        minute = int.tryParse(colonMinute) ?? 0;
      } else {
        minute = 0;
      }

      final normalizedHour = _to24Hour(hour, period);
      if (normalizedHour == 24 && minute != 0) continue;
      points.add(_TimePoint(normalizedHour * 60 + minute));
    }
    return points;
  }

  static int _to24Hour(int hour, String? period) {
    if (hour == 24) return 24;
    switch (period) {
      case '凌晨':
      case '早上':
      case '上午':
        return hour == 12 ? 0 : hour;
      case '中午':
        return hour < 6 ? hour + 12 : hour;
      case '下午':
      case '晚上':
        return hour < 12 ? hour + 12 : hour;
      default:
        // 中文口语中的“三点”通常指下午；明确说早上/上午时会走上面的分支。
        return hour >= 1 && hour <= 7 ? hour + 12 : hour;
    }
  }

  static int? _parseDuration(String text) {
    final match = _durationPattern.firstMatch(text);
    if (match == null) return null;
    final value = match.group(0)!;
    if (value == '半小时') return 30;
    if (value.endsWith('小时')) {
      final number = value.substring(0, value.length - 2).replaceAll('个', '');
      final hours = _parseNumber(number);
      return hours == null ? null : hours * 60;
    }
    final minutes = _parseNumber(value.substring(0, value.length - 2));
    return minutes;
  }

  static _EventTarget? _matchExistingEvent(
      String text, List<Category> categories) {
    final normalizedText = _normalize(text);
    final targets = <_EventTarget>[];
    for (final category in categories) {
      targets.add(_EventTarget(
        label: category.name,
        categoryId: category.id,
      ));
      for (final subCategory in category.subCategories) {
        targets.add(_EventTarget(
          label: subCategory,
          categoryId: category.id,
        ));
      }
    }

    final matches = targets
        .where((target) => normalizedText.contains(_normalize(target.label)))
        .toList()
      ..sort((a, b) => b.label.length.compareTo(a.label.length));
    return matches.isEmpty ? null : matches.first;
  }

  static String? _extractTemporaryLabel(String text) {
    var title = text.replaceAll(_clockPattern, ' ');
    title = title.replaceAll(_durationPattern, ' ');
    title = title.replaceAll(
      RegExp(r'今天|明天|后天|大后天|下周[一二三四五六日天1-7]'),
      ' ',
    );
    title = title.replaceAll(
      RegExp(r'帮我|请|安排|添加|记录|新建|设置|日程|一下|一个|从|到|至|之间'),
      ' ',
    );
    title = title.replaceAll(RegExp(r'[，。,.、；;：:～~\-—]'), ' ');
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return title.isEmpty ? null : title;
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[，。,.、；;：:～~\-—]'), '');
  }

  static int? _parseNumber(String value) {
    final trimmed = value.trim();
    final numeric = int.tryParse(trimmed);
    if (numeric != null) return numeric;
    if (trimmed.isEmpty) return null;

    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (trimmed == '十') return 10;
    if (trimmed.contains('十')) {
      final parts = trimmed.split('十');
      final tens = parts.first.isEmpty ? 1 : digits[parts.first];
      final ones =
          parts.length > 1 && parts.last.isNotEmpty ? digits[parts.last] : 0;
      if (tens == null || ones == null) return null;
      return tens * 10 + ones;
    }
    if (trimmed.length == 1) return digits[trimmed];
    return null;
  }
}

class _TimePoint {
  final int minutes;

  const _TimePoint(this.minutes);
}

class _EventTarget {
  final String label;
  final String categoryId;

  const _EventTarget({required this.label, required this.categoryId});
}
