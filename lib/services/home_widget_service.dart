import 'package:home_widget/home_widget.dart';
import '../models/time_slot.dart';

/// Android 桌面小组件数据桥接
class HomeWidgetService {
  static const String androidProvider =
      'com.example.time_manager.TimeManagerWidgetProvider';

  /// 与 App 首页一致，时间轴从 7:00 开始展示
  static const int dayStartHour = 7;
  static const int dayEndHour = 24;
  static int get daySpanHours => dayEndHour - dayStartHour;

  static Future<void> updateFromDay({
    required List<TimeSlot> slots,
    required DateTime date,
    required bool pendingSync,
  }) async {
    final now = DateTime.now();
    final isToday = _isSameDay(now, date);

    final eventCount = _countEventBlocks(slots);
    final recordedMinutes = _countRecordedMinutes(slots);
    final dateLabel = _formatDateLabel(date);
    final statsText =
        '$eventCount 个事件 · ${_formatDurationMinutes(recordedMinutes)}';
    final topCategories = _formatTopCategories(slots, maxItems: 3);

    String currentText;
    String nextText;
    if (isToday) {
      final idx = (now.hour * 6 + now.minute ~/ 10).clamp(0, slots.length - 1);
      currentText = _formatCurrent(slots, idx);
      nextText = _formatNext(slots, idx);
    } else {
      currentText = '当前：—';
      nextText = '接下来：—';
    }

    final hourColors = _hourColorsString(slots);

    await HomeWidget.saveWidgetData<String>('widget_date', dateLabel);
    await HomeWidget.saveWidgetData<String>('widget_stats', statsText);
    await HomeWidget.saveWidgetData<String>('widget_top_categories', topCategories);
    await HomeWidget.saveWidgetData<String>('widget_current', currentText);
    await HomeWidget.saveWidgetData<String>('widget_next', nextText);
    await HomeWidget.saveWidgetData<String>('widget_hour_colors', hourColors);
    await HomeWidget.saveWidgetData<bool>('widget_pending_sync', pendingSync);
    await HomeWidget.saveWidgetData<bool>('widget_is_today', isToday);
    await HomeWidget.saveWidgetData<int>(
      'widget_now_minutes',
      isToday ? now.hour * 60 + now.minute : -1,
    );
    await HomeWidget.saveWidgetData<int>(
      'widget_day_start_minutes',
      dayStartHour * 60,
    );
    await HomeWidget.saveWidgetData<int>(
      'widget_day_span_minutes',
      daySpanHours * 60,
    );

    await HomeWidget.updateWidget(qualifiedAndroidName: androidProvider);
  }

  static int _countEventBlocks(List<TimeSlot> slots) {
    int count = 0;
    bool inBlock = false;
    for (final slot in slots) {
      final hasEvent = slot.recorded && (slot.label?.isNotEmpty ?? false);
      if (hasEvent && !inBlock) {
        count++;
        inBlock = true;
      } else if (!hasEvent) {
        inBlock = false;
      }
    }
    return count;
  }

  static int _countRecordedMinutes(List<TimeSlot> slots) {
    int count = 0;
    for (final slot in slots) {
      if (slot.recorded && (slot.label?.isNotEmpty ?? false)) count++;
    }
    return count * 10;
  }

  static String _formatTopCategories(List<TimeSlot> slots, {int maxItems = 3}) {
    final stats = <String, int>{};
    for (final slot in slots) {
      if (slot.recorded && (slot.label?.isNotEmpty ?? false)) {
        stats[slot.label!] = (stats[slot.label!] ?? 0) + 10;
      }
    }
    if (stats.isEmpty) return '今日暂无分类统计';

    final sorted = stats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sorted
        .take(maxItems)
        .map((e) => '${e.key} ${_formatDurationMinutes(e.value, compact: true)}')
        .join(' · ');
  }

  static String _formatDurationMinutes(int minutes, {bool compact = false}) {
    if (minutes < 60) {
      return compact ? '${minutes}m' : '$minutes 分钟';
    }
    final hours = minutes / 60;
    if (hours == hours.roundToDouble()) {
      final h = hours.toInt();
      return compact ? '${h}h' : '$h 小时';
    }
    final text = hours.toStringAsFixed(1);
    return compact ? '${text}h' : '$text 小时';
  }

  static String _formatCurrent(List<TimeSlot> slots, int idx) {
    if (idx >= 0 &&
        idx < slots.length &&
        slots[idx].recorded &&
        (slots[idx].label?.isNotEmpty ?? false)) {
      return '当前：${slots[idx].label}';
    }
    return '当前：未记录';
  }

  static String _formatNext(List<TimeSlot> slots, int startIdx) {
    int i = startIdx;
    if (i < slots.length && slots[i].recorded) {
      final label = slots[i].label;
      while (i < slots.length && slots[i].recorded && slots[i].label == label) {
        i++;
      }
    }
    while (i < slots.length) {
      if (slots[i].recorded && (slots[i].label?.isNotEmpty ?? false)) {
        final label = slots[i].label!;
        final start = i;
        while (i < slots.length && slots[i].recorded && slots[i].label == label) {
          i++;
        }
        final time =
            '${(start ~/ 6).toString().padLeft(2, '0')}:${((start % 6) * 10).toString().padLeft(2, '0')}';
        return '接下来：$label $time';
      }
      i++;
    }
    return '接下来：无';
  }

  /// 7:00–24:00，每小时一个色块（共 17 段）
  static String _hourColorsString(List<TimeSlot> slots) {
    final parts = <String>[];
    for (int h = dayStartHour; h < dayEndHour; h++) {
      int? argb;
      for (int m = 0; m < 6; m++) {
        final idx = h * 6 + m;
        if (idx < slots.length &&
            slots[idx].recorded &&
            slots[idx].color != null) {
          argb = slots[idx].color!.toARGB32();
          break;
        }
      }
      parts.add(argb != null ? argb.toRadixString(16).padLeft(8, '0') : '0');
    }
    return parts.join(',');
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _formatDateLabel(DateTime date) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final w = weekdays[date.weekday - 1];
    return '${date.month}月${date.day}日 $w';
  }
}
