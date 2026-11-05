import '../models/time_block_reminder.dart';
import '../models/time_slot.dart';
import 'local_day_range.dart';
import 'time_slot_segment.dart';

/// 时间块提醒的通知 id 区间。
///
/// 2400–2831 = 2400 + 3 天 × 144 个可能的块起点。与写日记（2001/2002）、
/// 打卡（2200–2299）不重叠；id 由「日期 + 块起点」完全推导，不需要分配表。
const int timeBlockReminderIdBase = 2400;
const int timeBlockReminderDayCount = 3;
const int timeBlockReminderSlotCount = 144;
const int timeBlockReminderIdMax =
    timeBlockReminderIdBase + timeBlockReminderDayCount * timeBlockReminderSlotCount - 1;

/// 一个块在提醒计划里的一次出现。
class TimeBlockOccurrence {
  const TimeBlockOccurrence({
    required this.dateKey,
    required this.startIndex,
    required this.endIndex,
    required this.label,
    required this.categoryId,
    required this.startAt,
    required this.endAt,
    required this.fireAt,
  });

  final String dateKey;
  final int startIndex;
  final int endIndex;
  final String label;
  final String? categoryId;
  final DateTime startAt;
  final DateTime endAt;
  final DateTime fireAt;

  String get signature => '$startIndex|$endIndex|$label|${categoryId ?? ''}';

  String get timeRangeLabel => '${formatTimeBlockReminderClock(startAt)}–'
      '${formatTimeBlockReminderClock(endAt)}';
}

/// 计划里要登记的一条提醒。
class TimeBlockReminderScheduledItem {
  const TimeBlockReminderScheduledItem({
    required this.id,
    required this.occurrence,
    required this.fireAt,
    required this.catchUp,
  });

  final int id;
  final TimeBlockOccurrence occurrence;

  /// 补提醒用当前时刻，正常排程用事件开始时间减提前量。
  final DateTime fireAt;

  /// true 表示「事件已经开始但还没结束」，立刻弹出而不是等闹钟。
  final bool catchUp;

  String get title => occurrence.label;

  String get body => catchUp
      ? '${occurrence.timeRangeLabel} 已经开始，别忘了记录'
      : occurrence.fireAt == occurrence.startAt
          ? '${formatTimeBlockReminderClock(occurrence.startAt)} 开始'
          : '${formatTimeBlockReminderClock(occurrence.startAt)} 开始 · '
              '还剩 ${_leadMinutes(occurrence)} 分钟';

  int _leadMinutes(TimeBlockOccurrence occurrence) =>
      occurrence.startAt.difference(occurrence.fireAt).inMinutes;
}

/// 一轮 reconcile 的计算结果：要排什么、要取消什么、去重记录怎么更新。
class TimeBlockReminderPlan {
  const TimeBlockReminderPlan({
    required this.toSchedule,
    required this.staleIds,
    required this.desiredIds,
    required this.handled,
    required this.scheduledCount,
    required this.catchUpCount,
    required this.endedCount,
    required this.nextFireAt,
  });

  final List<TimeBlockReminderScheduledItem> toSchedule;
  final Set<int> staleIds;

  /// 窗口内仍然有效的通知 id（含已经在 pending 里的）。
  final Set<int> desiredIds;

  /// 本轮结束后应当落盘的去重记录（已裁剪到窗口内）。
  final Map<String, TimeBlockReminderFiredRecord> handled;

  /// 窗口内仍然有效的提醒条数（含已在 pending 里的）。
  final int scheduledCount;

  final int catchUpCount;
  final int endedCount;
  final DateTime? nextFireAt;
}

/// 本地日期转成「距 1970-01-01 的天数」。用 UTC 分量计算，避免夏令时把两天算成一天。
int timeBlockReminderEpochDay(DateTime day) =>
    DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// 通知 id：同一 (日期, 块起点) 恒等；窗口恰好 3 天，取模后不会撞车。
int timeBlockReminderNotificationId({
  required DateTime date,
  required int startIndex,
}) {
  final ring = timeBlockReminderEpochDay(date) % timeBlockReminderDayCount;
  return timeBlockReminderIdBase +
      ring * timeBlockReminderSlotCount +
      startIndex;
}

String timeBlockReminderDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String timeBlockReminderOccurrenceKey(String dateKey, int startIndex) =>
    '$dateKey#$startIndex';

/// 展示用的 HH:mm。
String formatTimeBlockReminderClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

bool _isReminderSlot(TimeSlot slot) =>
    slot.recorded &&
    !slot.isFromCalendar &&
    slot.color != null &&
    slot.label != null &&
    slot.label!.trim().isNotEmpty;

/// 把一天 144 个槽位聚合成事件块。
///
/// 跳过未记录、日历导入、没有事件名或没有颜色的槽位。相邻槽位用
/// [canJoinTimeSlots] 判断是否同块，与渲染和拖拽的口径一致。
List<TimeBlockOccurrence> collectTimeBlockOccurrences(
  TimeBlockReminderDay day, {
  required int leadMinutes,
}) {
  final slots = day.slots;
  final result = <TimeBlockOccurrence>[];
  if (slots.isEmpty) return result;

  final date = localDayOf(day.date);
  final dateKey = timeBlockReminderDateKey(date);
  var index = 0;
  while (index < slots.length) {
    if (!_isReminderSlot(slots[index])) {
      index++;
      continue;
    }
    var end = index;
    while (end + 1 < slots.length &&
        _isReminderSlot(slots[end + 1]) &&
        canJoinTimeSlots(slots[end], slots[end + 1])) {
      end++;
    }
    final startAt = date.add(Duration(minutes: index * 10));
    final endAt = date.add(Duration(minutes: (end + 1) * 10));
    result.add(
      TimeBlockOccurrence(
        dateKey: dateKey,
        startIndex: index,
        endIndex: end,
        label: slots[index].label!.trim(),
        categoryId: slots[index].categoryId,
        startAt: startAt,
        endAt: endAt,
        fireAt: startAt.subtract(Duration(minutes: leadMinutes)),
      ),
    );
    index = end + 1;
  }
  return result;
}

/// 生成一轮提醒计划。
///
/// 判定顺序不可颠倒：已结束 → 跳过；已过触发时刻但未结束 → 补提醒；
/// 其余 → 正常排程。所有判定只依赖入参，方便单测。
TimeBlockReminderPlan buildTimeBlockReminderPlan({
  required List<TimeBlockReminderDay> days,
  required int leadMinutes,
  required DateTime now,
  required Map<String, TimeBlockReminderFiredRecord> handled,
  required Set<int> pendingIds,
  required Set<int> knownIds,
}) {
  final toSchedule = <TimeBlockReminderScheduledItem>[];
  final desiredIds = <int>{};
  final nextHandled = <String, TimeBlockReminderFiredRecord>{};
  var catchUpCount = 0;
  var endedCount = 0;
  DateTime? nextFireAt;

  void trackNext(DateTime at) {
    if (!at.isAfter(now)) return;
    if (nextFireAt == null || at.isBefore(nextFireAt!)) nextFireAt = at;
  }

  for (final day in days) {
    final occurrences = collectTimeBlockOccurrences(
      day,
      leadMinutes: leadMinutes,
    );
    for (final occurrence in occurrences) {
      final key = timeBlockReminderOccurrenceKey(
        occurrence.dateKey,
        occurrence.startIndex,
      );
      final id = timeBlockReminderNotificationId(
        date: day.date,
        startIndex: occurrence.startIndex,
      );

      // 已经结束：不再提醒，也不保留去重记录（块可能被恢复成新的一次）
      if (!now.isBefore(occurrence.endAt)) {
        endedCount++;
        continue;
      }

      desiredIds.add(id);
      final record = handled[key];
      final alreadyHandled = record != null &&
          record.signature == occurrence.signature &&
          record.fireAtEpochMs == occurrence.fireAt.millisecondsSinceEpoch;

      if (!now.isBefore(occurrence.fireAt)) {
        // 已过触发时刻但还没结束：补提醒
        if (pendingIds.contains(id) || alreadyHandled) {
          nextHandled[key] = TimeBlockReminderFiredRecord(
            signature: occurrence.signature,
            fireAtEpochMs: occurrence.fireAt.millisecondsSinceEpoch,
            catchUp: true,
          );
          continue;
        }
        toSchedule.add(
          TimeBlockReminderScheduledItem(
            id: id,
            occurrence: occurrence,
            fireAt: now,
            catchUp: true,
          ),
        );
        catchUpCount++;
        nextHandled[key] = TimeBlockReminderFiredRecord(
          signature: occurrence.signature,
          fireAtEpochMs: occurrence.fireAt.millisecondsSinceEpoch,
          catchUp: true,
        );
        continue;
      }

      // 还没到触发时刻：正常排程
      if (pendingIds.contains(id) && alreadyHandled) {
        nextHandled[key] = record;
        trackNext(occurrence.fireAt);
        continue;
      }
      toSchedule.add(
        TimeBlockReminderScheduledItem(
          id: id,
          occurrence: occurrence,
          fireAt: occurrence.fireAt,
          catchUp: false,
        ),
      );
      nextHandled[key] = TimeBlockReminderFiredRecord(
        signature: occurrence.signature,
        fireAtEpochMs: occurrence.fireAt.millisecondsSinceEpoch,
        catchUp: false,
      );
      trackNext(occurrence.fireAt);
    }
  }

  final staleIds = <int>{}
    ..addAll(pendingIds.where((id) => !desiredIds.contains(id)))
    ..addAll(knownIds.where((id) => !desiredIds.contains(id)));

  return TimeBlockReminderPlan(
    toSchedule: toSchedule,
    staleIds: staleIds,
    desiredIds: desiredIds,
    handled: nextHandled,
    scheduledCount: desiredIds.length,
    catchUpCount: catchUpCount,
    endedCount: endedCount,
    nextFireAt: nextFireAt,
  );
}

/// 只保留通知 id 区间内的 id：绝不误动写日记与打卡提醒。
Set<int> timeBlockReminderIdsInRange(Iterable<int> ids) => ids
    .where((id) => id >= timeBlockReminderIdBase && id <= timeBlockReminderIdMax)
    .toSet();
