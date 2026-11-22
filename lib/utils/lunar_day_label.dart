import 'package:lunar/lunar.dart';

/// 日期格里显示的一行农历文案。
///
/// [text] 是格子里真正渲染的内容：平时是农历日（初六），初一换成农历月份
/// （九月），节日或节气优先显示名称（中秋节 / 霜降）。
/// [semanticText] 给读屏用，保留完整农历日期与节日名。
/// [emphasized] 标记节日 / 节气，供调用方加重文字颜色。
class LunarDayLabel {
  const LunarDayLabel({
    required this.text,
    required this.semanticText,
    this.emphasized = false,
  });

  final String text;
  final String semanticText;
  final bool emphasized;
}

/// 只在日期格上显示常见节日名。
///
/// 上游 [Lunar.getFestivals] / [Solar.getFestivals] 里还有「接神日」
/// 「消费者权益日」「万圣节前夜」这类名字，日历格子放不下也会变成噪声，
/// 这里只保留大众熟知的一批。清明本身是节气，会按节气显示，无需单列。
const Set<String> _lunarFestivals = {
  '春节',
  '元宵节',
  '端午节',
  '七夕节',
  '中秋节',
  '重阳节',
  '腊八节',
  '除夕',
};

const Set<String> _solarFestivals = {
  '元旦节',
  '劳动节',
  '国庆节',
};

/// 缓存上限：约 24 个整屏日期。超出后整体清空，不做 LRU——逻辑简单，
/// 内存有界，重复计算的成本也只是一次整屏换算。
const int _maxCacheEntries = 1024;

final Map<String, LunarDayLabel> _cache = {};

/// 取某一天的农历展示文案。
///
/// 传入的时分秒会被丢弃，按本地年月日归一化后换算；如果拿到的是 UTC
/// 时间或带时区的时间戳，调用方要先 `toLocal()` 再传进来，否则可能差一天。
LunarDayLabel lunarDayLabel(DateTime date) {
  final key = _dateKey(date);
  final cached = _cache[key];
  if (cached != null) return cached;
  final label = _buildLabel(DateTime(date.year, date.month, date.day));
  if (_cache.length >= _maxCacheEntries) _cache.clear();
  _cache[key] = label;
  return label;
}

/// 批量取农历文案，key 为归一化后的 `yyyy-MM-dd`。
///
/// 日历一次要画 42 格，先按 key 去重再换算，同一天重复传入只算一次。
Map<String, LunarDayLabel> lunarDayLabelsForDates(Iterable<DateTime> dates) {
  final result = <String, LunarDayLabel>{};
  for (final date in dates) {
    result[_dateKey(date)] = lunarDayLabel(date);
  }
  return result;
}

/// 清空缓存，仅测试与调试用。
void clearLunarDayLabelCache() => _cache.clear();

LunarDayLabel _buildLabel(DateTime date) {
  final lunar = Lunar.fromDate(date);
  final lunarText = '农历${lunar.getMonthInChinese()}月${lunar.getDayInChinese()}';

  for (final festival in lunar.getFestivals()) {
    if (_lunarFestivals.contains(festival)) {
      return LunarDayLabel(
        text: festival,
        semanticText: '$lunarText，$festival',
        emphasized: true,
      );
    }
  }
  for (final festival in Solar.fromDate(date).getFestivals()) {
    if (_solarFestivals.contains(festival)) {
      return LunarDayLabel(
        text: festival,
        semanticText: '$lunarText，$festival',
        emphasized: true,
      );
    }
  }

  final jieQi = lunar.getJieQi();
  if (jieQi.isNotEmpty) {
    return LunarDayLabel(
      text: jieQi,
      semanticText: '$lunarText，$jieQi',
      emphasized: true,
    );
  }

  final dayText = lunar.getDayInChinese();
  if (dayText == '初一') {
    return LunarDayLabel(
      text: '${lunar.getMonthInChinese()}月',
      semanticText: lunarText,
    );
  }
  return LunarDayLabel(text: dayText, semanticText: lunarText);
}

String _dateKey(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
