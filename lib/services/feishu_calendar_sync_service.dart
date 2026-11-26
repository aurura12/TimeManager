import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../models/diary_kind.dart';
import '../models/feishu_calendar_models.dart';
import '../models/time_slot.dart';
import 'feishu_calendar_api.dart';
import 'feishu_calendar_log.dart';
import 'feishu_calendar_planner.dart';
import 'feishu_credentials_store.dart';
import 'feishu_oauth_service.dart';

/// 编排「时间块 → 飞书日历」的同步，并对外暴露进度供设置页监听。
class FeishuCalendarSyncService extends ChangeNotifier {
  FeishuCalendarSyncService({
    FeishuCalendarApi? api,
    FeishuOAuthService? oauth,
  })  : _api = api ?? FeishuCalendarApi(),
        _oauth = oauth ?? FeishuOAuthService();

  static final FeishuCalendarSyncService instance = FeishuCalendarSyncService();

  final FeishuCalendarApi _api;
  final FeishuOAuthService _oauth;

  final Map<DiaryKind, String> _calendarIds = {};

  bool _syncing = false;
  bool _cancelRequested = false;
  int _completed = 0;
  int _total = 0;
  String? _currentDateKey;

  bool get syncing => _syncing;
  int get completed => _completed;
  int get total => _total;
  String? get currentDateKey => _currentDateKey;

  void cancel() {
    if (_syncing) _cancelRequested = true;
  }

  /// 同一天的同步串行排队。
  ///
  /// 自动推送与手动全量同步都可能命中同一天：两边同时读到「远端还没有这些
  /// 日程」，就会各自创建一份，飞书上出现重复日程。这里按「身份 + 日期」
  /// 排队，后一个等前一个写完再重新拉取求差集。
  final Map<String, Future<void>> _dayChains = {};

  /// 同步单日：拉当天本 App 事件 → 与本地槽位求差集 → 增删。
  Future<FeishuDaySyncOutcome> syncDay({
    required DiaryKind kind,
    required DateTime date,
    required List<TimeSlot> slots,
  }) {
    final key = '${kind.code}|${_dateKey(date)}';
    final previous = _dayChains[key];
    final gate = Completer<void>();
    _dayChains[key] = gate.future;
    return _runQueuedDay(
      previous,
      gate,
      key,
      kind: kind,
      date: date,
      slots: slots,
    );
  }

  Future<FeishuDaySyncOutcome> _runQueuedDay(
    Future<void>? previous,
    Completer<void> gate,
    String key, {
    required DiaryKind kind,
    required DateTime date,
    required List<TimeSlot> slots,
  }) async {
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // 前一次失败不影响这一次：它自己会把错误报给调用方。
      }
    }
    try {
      return await _syncDayUnsafe(kind: kind, date: date, slots: slots);
    } finally {
      gate.complete();
      if (identical(_dayChains[key], gate.future)) {
        _dayChains.remove(key);
      }
    }
  }

  Future<FeishuDaySyncOutcome> _syncDayUnsafe({
    required DiaryKind kind,
    required DateTime date,
    required List<TimeSlot> slots,
  }) async {
    final dateKey = _dateKey(date);
    final tokenResult = await _oauth.ensureAccessToken(kind);
    if (tokenResult.tokens == null) {
      // 网络失败只报错、不标记重新授权：把队列留住，下次自动重试。
      return FeishuDaySyncOutcome.failed(
        dateKey,
        tokenResult.error ?? '飞书授权已失效，请重新授权',
        needReauth: tokenResult.needReauth,
      );
    }

    final calendarResult = await _calendarId(kind);
    final calendarId = calendarResult.data;
    if (!calendarResult.success || calendarId == null) {
      // 主日历读不到时要把飞书给的真实原因带出去：权限类失败（99991679）
      // 以前被兜底成「没有找到飞书主日历」，用户完全看不出该重新授权。
      return _fail(
        kind,
        dateKey,
        calendarResult.error ?? '没有找到飞书主日历',
        needReauth: calendarResult.unauthorized,
      );
    }

    final pageResult = await _withToken(
      kind,
      (accessToken) => _api.listDayEvents(
        accessToken: accessToken,
        calendarId: calendarId,
        day: date,
      ),
    );
    if (!pageResult.success || pageResult.data == null) {
      return _fail(
        kind,
        dateKey,
        pageResult.error ?? '读取飞书日程失败',
        needReauth: pageResult.unauthorized,
      );
    }
    final page = pageResult.data!;
    if (page.truncated) {
      // fail-closed：没读全就不能删，交给下一次重试。
      return _fail(kind, dateKey, '当天日程太多，读取被截断，稍后重试');
    }

    final drafts = mergeSlotsToEvents(slots, date);
    final diff = diffFeishuDayEvents(
      local: drafts,
      remote: page.events,
      remoteTruncated: false,
    );

    var deleted = 0;
    for (final event in diff.toDelete) {
      if (_cancelRequested) break;
      final result = await _withToken(
        kind,
        (accessToken) => _api.deleteEvent(
          accessToken: accessToken,
          calendarId: calendarId,
          eventId: event.eventId,
        ),
      );
      if (!result.success) {
        return _fail(
          kind,
          dateKey,
          result.error ?? '删除飞书日程失败',
          needReauth: result.unauthorized,
        );
      }
      deleted++;
    }

    var created = 0;
    if (!_cancelRequested) {
      final timezone = await _localTimezone();
      for (final draft in diff.toCreate) {
        if (_cancelRequested) break;
        final result = await _withToken(
          kind,
          (accessToken) => _api.createEvent(
            accessToken: accessToken,
            calendarId: calendarId,
            body: buildFeishuEventBody(draft, timezone: timezone),
          ),
        );
        if (!result.success) {
          return _fail(
            kind,
            dateKey,
            result.error ?? '创建飞书日程失败',
            needReauth: result.unauthorized,
          );
        }
        created++;
      }
    }

    if (created > 0) {
      await _collapseDuplicates(
        kind: kind,
        calendarId: calendarId,
        date: date,
        dateKey: dateKey,
      );
    }

    await _updateSyncedIndex(kind, dateKey, drafts);
    feishuLog('飞书同步 $dateKey：新增 $created，删除 $deleted');
    return FeishuDaySyncOutcome(
      dateKey: dateKey,
      success: true,
      created: created,
      deleted: deleted,
    );
  }

  /// 批量同步（手动补同步用），逐日汇总失败，不因单日失败中断。
  Future<FeishuSyncSummary> syncDates({
    required DiaryKind kind,
    required Map<String, List<TimeSlot>> slotsByDate,
  }) async {
    if (_syncing) {
      return const FeishuSyncSummary(
        totalDays: 0,
        successDays: 0,
        created: 0,
        deleted: 0,
        failedDates: [],
        message: '已有飞书同步在进行中',
      );
    }

    final entries = slotsByDate.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    _syncing = true;
    _cancelRequested = false;
    _completed = 0;
    _total = entries.length;
    _currentDateKey = null;
    notifyListeners();

    var successDays = 0;
    var created = 0;
    var deleted = 0;
    var needReauth = false;
    String? firstError;
    final failedDates = <String>[];
    feishuLog('开始同步飞书日历：${entries.length} 天（身份 ${kind.code}）');

    try {
      for (final entry in entries) {
        if (_cancelRequested) break;
        _currentDateKey = entry.key;
        notifyListeners();
        final date = _parseDateKey(entry.key);
        if (date == null) {
          failedDates.add(entry.key);
          _completed++;
          continue;
        }
        final outcome = await syncDay(
          kind: kind,
          date: date,
          slots: entry.value,
        );
        if (outcome.success) {
          successDays++;
          created += outcome.created;
          deleted += outcome.deleted;
        } else {
          failedDates.add(entry.key);
          firstError ??= outcome.message;
          needReauth = needReauth || outcome.needReauth;
          feishuLogWarning(
            '飞书同步失败：${entry.key} · ${outcome.message ?? '未知原因'}',
          );
          if (outcome.needReauth) break;
        }
        _completed++;
        notifyListeners();
      }
    } finally {
      _syncing = false;
      _currentDateKey = null;
      notifyListeners();
    }

    final summary = FeishuSyncSummary(
      totalDays: entries.length,
      successDays: successDays,
      created: created,
      deleted: deleted,
      failedDates: failedDates,
      needReauth: needReauth,
      cancelled: _cancelRequested,
      firstError: firstError,
    );
    if (!summary.needReauth) {
      await FeishuCredentialStore.saveLastSync(
        kind,
        at: DateTime.now(),
        summary: summary.describe(),
      );
    }
    return summary;
  }

  /// 统一出口：失败一定写进运行日志，设置页也会拿到同样的文案。
  ///
  /// 需要重新授权时顺手把标记落盘，设置页的状态才会从「已连接」变成
  /// 「授权已失效，需要重新授权」——权限类失败（99991679）尤其是这样。
  FeishuDaySyncOutcome _fail(
    DiaryKind kind,
    String dateKey,
    String message, {
    bool needReauth = false,
  }) {
    feishuLogWarning('飞书同步失败：$dateKey · $message');
    if (needReauth) {
      unawaited(FeishuCredentialStore.saveNeedsReauth(kind, true));
    }
    return FeishuDaySyncOutcome.failed(
      dateKey,
      message,
      needReauth: needReauth,
    );
  }

  Future<FeishuApiResult<String>> _calendarId(DiaryKind kind) async {
    final cached = _calendarIds[kind];
    if (cached != null) return FeishuApiResult.ok(cached);
    final stored = await FeishuCredentialStore.loadPrimaryCalendarId(kind);
    if (stored != null) {
      _calendarIds[kind] = stored;
      return FeishuApiResult.ok(stored);
    }
    final result = await _withToken(
      kind,
      (accessToken) => _api.fetchPrimaryCalendarId(accessToken),
    );
    final id = result.data;
    if (!result.success || id == null || id.isEmpty) {
      return FeishuApiResult.failed(
        result.error ?? '没有找到飞书主日历',
        unauthorized: result.unauthorized,
      );
    }
    _calendarIds[kind] = id;
    await FeishuCredentialStore.savePrimaryCalendarId(kind, id);
    return FeishuApiResult.ok(id);
  }

  /// 调飞书接口；令牌失效时刷新一次并重放一次。
  Future<FeishuApiResult<T>> _withToken<T>(
    DiaryKind kind,
    Future<FeishuApiResult<T>> Function(String accessToken) call,
  ) async {
    final tokenResult = await _oauth.ensureAccessToken(kind);
    final tokens = tokenResult.tokens;
    if (tokens == null) {
      return FeishuApiResult.failed(
        tokenResult.error ?? '飞书授权已失效，请重新授权',
        unauthorized: tokenResult.needReauth,
      );
    }
    final first = await call(tokens.accessToken);
    if (!first.unauthorized) return first;
    final refreshed = await _oauth.refreshAccessToken(kind);
    final refreshedTokens = refreshed.tokens;
    if (refreshedTokens == null) {
      // 暂时刷新不了就如实报错；只有真的失效才让上层要求重新授权。
      return FeishuApiResult.failed(
        refreshed.error ?? first.error ?? '飞书授权已失效，请重新授权',
        unauthorized: refreshed.needReauth,
      );
    }
    return call(refreshedTokens.accessToken);
  }

  /// 收敛并发创建出来的重复日程。
  ///
  /// 两台设备同时推同一天时，各自都读到「远端还没有这条」，就会各建一份。
  /// 创建成功后立刻再列一次当天，按（标题, 开始, 结束）分组，多出来的删掉。
  /// 保留 `event_id` 最小的一条，保证两台设备算出同一个保留者。
  /// 属于尽力而为：失败只记日志，不影响本次同步结果。
  Future<void> _collapseDuplicates({
    required DiaryKind kind,
    required String calendarId,
    required DateTime date,
    required String dateKey,
  }) async {
    final pageResult = await _withToken(
      kind,
      (accessToken) => _api.listDayEvents(
        accessToken: accessToken,
        calendarId: calendarId,
        day: date,
      ),
    );
    final page = pageResult.data;
    if (!pageResult.success || page == null || page.truncated) return;

    final groups = <String, List<FeishuRemoteEvent>>{};
    for (final event in page.events) {
      final key =
          '${event.summary}|${event.startSeconds}|${event.endSeconds}';
      groups.putIfAbsent(key, () => <FeishuRemoteEvent>[]).add(event);
    }

    var collapsed = 0;
    for (final group in groups.values) {
      if (group.length < 2) continue;
      group.sort((a, b) => a.eventId.compareTo(b.eventId));
      for (final extra in group.skip(1)) {
        final result = await _withToken(
          kind,
          (accessToken) => _api.deleteEvent(
            accessToken: accessToken,
            calendarId: calendarId,
            eventId: extra.eventId,
          ),
        );
        if (result.success) {
          collapsed++;
        } else {
          feishuLogWarning(
            '飞书重复日程清理失败：$dateKey · ${result.error ?? '未知原因'}',
          );
        }
      }
    }
    if (collapsed > 0) {
      feishuLog('飞书同步 $dateKey：清理重复日程 $collapsed');
    }
  }

  Future<void> _updateSyncedIndex(
    DiaryKind kind,
    String dateKey,
    List<FeishuEventDraft> drafts,
  ) async {
    final synced = (await FeishuCredentialStore.loadSyncedDates(kind)).toSet();
    if (drafts.isEmpty) {
      synced.remove(dateKey);
    } else {
      synced.add(dateKey);
    }
    await FeishuCredentialStore.saveSyncedDates(kind, synced);
  }

  Future<String> _localTimezone() async {
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      final identifier = info.identifier;
      return identifier.isEmpty ? 'Asia/Shanghai' : identifier;
    } catch (_) {
      return 'Asia/Shanghai';
    }
  }

  static String _dateKey(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static DateTime? _parseDateKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }
}
