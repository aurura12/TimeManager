import 'dart:convert';

import 'package:home_widget/home_widget.dart';
import '../models/time_slot.dart';

/// Android 桌面小组件数据桥接
class HomeWidgetService {
  static const String androidProvider =
      'com.example.time_manager.TimeManagerWidgetProvider';

  /// 小组件启动 URI 的固定协议。URI 只在 Android 原生小组件内部生成，
  /// Dart 侧仍会再次严格校验，避免把任意外部 Intent 当成应用动作。
  static const String actionUriScheme = 'time-manager';
  static const String actionUriHost = 'widget';

  /// 小组件启动请求。null 表示本次不是从小组件启动；非 null 一定是
  /// 已收到过 URI（包括校验失败的 URI），这样坏参数不会静默跳首页。
  static HomeWidgetActionRequest? parseActionUri(Uri? uri) {
    if (uri == null) return null;

    final actionValues = uri.queryParametersAll['action'];
    final validShape = uri.toString().length <= 256 &&
        uri.scheme == actionUriScheme &&
        uri.host == actionUriHost &&
        uri.path.isEmpty &&
        uri.fragment.isEmpty &&
        uri.userInfo.isEmpty &&
        uri.port == 0 &&
        uri.queryParametersAll.length == 1 &&
        actionValues?.length == 1;
    if (!validShape) {
      return HomeWidgetActionRequest(
          uri: uri, action: HomeWidgetAction.invalid);
    }

    final action = switch (actionValues!.single) {
      'today_records' => HomeWidgetAction.todayRecords,
      'search' => HomeWidgetAction.search,
      'sync_center' => HomeWidgetAction.syncCenter,
      _ => HomeWidgetAction.invalid,
    };
    return HomeWidgetActionRequest(uri: uri, action: action);
  }

  /// 为原生小组件生成固定格式的 URI，避免在多个入口各自拼接参数。
  static Uri actionUri(HomeWidgetAction action) {
    final value = switch (action) {
      HomeWidgetAction.todayRecords => 'today_records',
      HomeWidgetAction.search => 'search',
      HomeWidgetAction.syncCenter => 'sync_center',
      HomeWidgetAction.invalid => throw ArgumentError('invalid widget action'),
    };
    return Uri(
      scheme: actionUriScheme,
      host: actionUriHost,
      queryParameters: {'action': value},
    );
  }

  /// 将动作反馈写回小组件，原生端只显示短时间，避免过期状态长期误导用户。
  static Future<void> reportActionStatus(
    String message, {
    bool isError = false,
  }) async {
    final normalized = message.trim();
    if (normalized.isEmpty) return;
    final safeMessage =
        normalized.length <= 80 ? normalized : normalized.substring(0, 80);
    await HomeWidget.saveWidgetData<String>(
      'widget_action_status',
      safeMessage,
    );
    await HomeWidget.saveWidgetData<bool>(
        'widget_action_status_error', isError);
    await HomeWidget.saveWidgetData<int>(
      'widget_action_status_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    await HomeWidget.updateWidget(qualifiedAndroidName: androidProvider);
  }

  /// 与 App 首页一致，时间轴从 7:00 开始展示
  static const int dayStartHour = 7;
  static const int dayEndHour = 24;
  static int get daySpanHours => dayEndHour - dayStartHour;

  /// 小组件时间轴专用色板：按时间顺序为每个连续时段分配，与 App 内分类色无关
  static const List<int> _timelinePalette = [
    0xFF9CB86A, // 绿
    0xFF4A90E2, // 蓝
    0xFFD4AF37, // 金
    0xFF7986CB, // 靛
    0xFF4DB6AC, // 青
    0xFFE57373, // 红
    0xFFFF8A65, // 橙
    0xFFBA68C8, // 紫
    0xFFA1887F, // 棕
    0xFF26A69A, // 深青
  ];

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

    final timelineBlocks = _timelineBlocksJson(slots);

    await HomeWidget.saveWidgetData<String>('widget_date', dateLabel);
    await HomeWidget.saveWidgetData<String>('widget_stats', statsText);
    await HomeWidget.saveWidgetData<String>(
        'widget_top_categories', topCategories);
    await HomeWidget.saveWidgetData<String>('widget_current', currentText);
    await HomeWidget.saveWidgetData<String>('widget_next', nextText);
    await HomeWidget.saveWidgetData<String>(
        'widget_timeline_blocks', timelineBlocks);
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
        .map(
            (e) => '${e.key} ${_formatDurationMinutes(e.value, compact: true)}')
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
        while (
            i < slots.length && slots[i].recorded && slots[i].label == label) {
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

  /// 连续时段 JSON，供原生时间轴绘制色块与名称
  static String _timelineBlocksJson(List<TimeSlot> slots) {
    final blocks = _timelineBlocksWithPalette(slots);
    final dayStartMin = dayStartHour * 60;
    final dayEndMin = dayEndHour * 60;

    final list = <Map<String, dynamic>>[];
    for (final block in blocks) {
      final startMin = _slotIndexToMinutes(block.startIndex);
      final endMin = _slotIndexToMinutes(block.endIndex + 1);
      if (endMin <= dayStartMin || startMin >= dayEndMin) continue;
      list.add({
        's': startMin,
        'e': endMin,
        'l': block.label,
        'c': block.colorArgb,
      });
    }
    return json.encode(list);
  }

  static int _slotIndexToMinutes(int index) =>
      (index ~/ 6) * 60 + (index % 6) * 10;

  /// 将一天拆成连续记录段，每段使用色板中不同颜色（相邻段必可区分）
  static List<_TimelineBlock> _timelineBlocksWithPalette(List<TimeSlot> slots) {
    final blocks = <_TimelineBlock>[];
    int paletteIndex = 0;
    int i = 0;
    while (i < slots.length) {
      if (slots[i].recorded && (slots[i].label?.isNotEmpty ?? false)) {
        final label = slots[i].label;
        final start = i;
        while (
            i < slots.length && slots[i].recorded && slots[i].label == label) {
          i++;
        }
        blocks.add(_TimelineBlock(
          startIndex: start,
          endIndex: i - 1,
          label: label!,
          colorArgb: _timelinePalette[paletteIndex % _timelinePalette.length],
        ));
        paletteIndex++;
      } else {
        i++;
      }
    }
    return blocks;
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _formatDateLabel(DateTime date) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final w = weekdays[date.weekday - 1];
    return '${date.month}月${date.day}日 $w';
  }
}

enum HomeWidgetAction {
  todayRecords,
  search,
  syncCenter,
  invalid,
}

class HomeWidgetActionRequest {
  const HomeWidgetActionRequest({required this.uri, required this.action});

  final Uri uri;
  final HomeWidgetAction action;

  String get routeName => switch (action) {
        HomeWidgetAction.todayRecords => '/widget/today-records',
        HomeWidgetAction.search => '/widget/search',
        HomeWidgetAction.syncCenter => '/widget/sync-center',
        HomeWidgetAction.invalid => '/widget/invalid-action',
      };
}

class _TimelineBlock {
  final int startIndex;
  final int endIndex;
  final String label;
  final int colorArgb;

  _TimelineBlock({
    required this.startIndex,
    required this.endIndex,
    required this.label,
    required this.colorArgb,
  });
}
