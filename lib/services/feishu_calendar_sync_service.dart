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

  /// 同步单日：拉当天本 App 事件 → 与本地槽位求差集 → 增删。
  Future<FeishuDaySyncOutcome> syncDay({
    required DiaryKind kind,
    required DateTime date,
    required List<TimeSlot> slots,
  }) async {
    final dateKey = _dateKey(date);
    final token = await _oauth.ensureAccessToken(kind);
    if (token == null) {
      return FeishuDaySyncOutcome.failed(
        dateKey,
        '飞书授权已失效，请重新授权',
        needReauth: true,
      );
    }

    final calendarId = await _calendarId(kind);
    if (calendarId == null) {
      return FeishuDaySyncOutcome.failed(dateKey, '没有找到飞书主日历');
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
      return FeishuDaySyncOutcome.failed(
        dateKey,
        pageResult.error ?? '读取飞书日程失败',
        needReauth: pageResult.unauthorized,
      );
    }
    final page = pageResult.data!;
    if (page.truncated) {
      // fail-closed：没读全就不能删，交给下一次重试。
      return FeishuDaySyncOutcome.failed(dateKey, '当天日程太多，读取被截断，稍后重试');
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
        return FeishuDaySyncOutcome.failed(
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
          return FeishuDaySyncOutcome.failed(
            dateKey,
            result.error ?? '创建飞书日程失败',
            needReauth: result.unauthorized,
          );
        }
        created++;
      }
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
    final failedDates = <String>[];

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
          needReauth = needReauth || outcome.needReauth;
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

  Future<String?> _calendarId(DiaryKind kind) async {
    final cached = _calendarIds[kind];
    if (cached != null) return cached;
    final stored = await FeishuCredentialStore.loadPrimaryCalendarId(kind);
    if (stored != null) {
      _calendarIds[kind] = stored;
      return stored;
    }
    final result = await _withToken(
      kind,
      (accessToken) => _api.fetchPrimaryCalendarId(accessToken),
    );
    final id = result.data;
    if (!result.success || id == null || id.isEmpty) return null;
    _calendarIds[kind] = id;
    await FeishuCredentialStore.savePrimaryCalendarId(kind, id);
    return id;
  }

  /// 调飞书接口；令牌失效时刷新一次并重放一次。
  Future<FeishuApiResult<T>> _withToken<T>(
    DiaryKind kind,
    Future<FeishuApiResult<T>> Function(String accessToken) call,
  ) async {
    final tokens = await _oauth.ensureAccessToken(kind);
    if (tokens == null) {
      return FeishuApiResult.failed('飞书授权已失效，请重新授权', unauthorized: true);
    }
    final first = await call(tokens.accessToken);
    if (!first.unauthorized) return first;
    final refreshed = await _oauth.refreshAccessToken(kind);
    if (refreshed == null) return first;
    return call(refreshed.accessToken);
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
