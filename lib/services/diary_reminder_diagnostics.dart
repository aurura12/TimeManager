import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_log_entry.dart';
import 'app_log_service.dart';

/// 原生侧上报的一条提醒事件。
@immutable
class DiaryReminderNativeEvent {
  const DiaryReminderNativeEvent({
    required this.id,
    required this.at,
    required this.code,
    this.kind,
    this.detail,
  });

  /// 原生生成的唯一 ID，同时用作日志的幂等键。
  final String id;

  /// 事件在原生侧的真实发生时间（UTC）。
  final DateTime at;

  /// 事件码，取值见插件 fork 的 `DiaryReminderNativeEventStore`。
  final String code;

  /// 事件归属的提醒类型（`diary_reminder` / `check_in_reminder`）。
  /// 缺失时按写日记提醒处理（旧版本 fork 只埋了这一类）。
  final String? kind;

  final String? detail;

  /// 解析失败返回 null，由调用方跳过该条。
  static DiaryReminderNativeEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final at = raw['at'];
    final code = raw['code'];
    if (id is! String || at is! int || code is! String) return null;
    final detail = raw['detail'];
    final kind = raw['kind'];
    return DiaryReminderNativeEvent(
      id: id,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      code: code,
      kind: kind is String && kind.isNotEmpty ? kind : null,
      detail: detail is String && detail.isNotEmpty ? detail : null,
    );
  }
}

/// 把原生提醒事件导入「运行日志」。
///
/// 到点时 Dart 不运行，`AppLogService` 收不到回调，所以触发过程由插件的原生 receiver
/// 写进一个有界队列，App 启动或回到前台时再导进来。
///
/// 导入采用「先写入成功、再确认删除」：只有日志明确落到磁盘，才把对应事件从原生队列移走，
/// 写入失败的事件留在队列里等下次重试。
class DiaryReminderDiagnostics {
  const DiaryReminderDiagnostics._();

  static const String channelName =
      'com.example.time_manager/diary_reminder_events';
  static const String logSource = 'diary_reminder';

  static const MethodChannel _defaultChannel = MethodChannel(channelName);

  @visibleForTesting
  static MethodChannel? channelOverride;

  @visibleForTesting
  static AppLogService? logServiceOverride;

  @visibleForTesting
  static void resetForTesting() {
    channelOverride = null;
    logServiceOverride = null;
    _ongoing = null;
  }

  static MethodChannel get _channel => channelOverride ?? _defaultChannel;

  static AppLogService get _log => logServiceOverride ?? AppLogService.instance;

  /// single-flight：冷启动与 resume 可能同时请求导入，只允许一次读写确认事务。
  static Future<int>? _ongoing;

  /// 导入待处理的提醒事件，返回**本次确认已持久化**的条数。
  ///
  /// 重复导入（例如上次确认删除失败后重发）也会再次计入——那条事件确实已经在磁盘上。
  /// 幂等保证体现在日志条目不重复，而不是这个计数。
  /// 永不抛出：诊断失败不应该影响启动或恢复流程。
  static Future<int> importPendingEvents() =>
      _ongoing ??= _import().whenComplete(() => _ongoing = null);

  static Future<int> _import() async {
    final List<DiaryReminderNativeEvent> events;
    final int dropped;
    try {
      final raw = await _channel.invokeMethod<String>('readPending');
      final parsed = _parsePayload(raw);
      events = parsed.events;
      dropped = parsed.dropped;
    } on MissingPluginException {
      // 桌面端没有接入这个通道，属于正常情况
      return 0;
    } catch (error, stackTrace) {
      _log.warning(
        '读取原生提醒事件失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
      return 0;
    }

    if (events.isEmpty && dropped == 0) return 0;

    var imported = 0;
    final confirmed = <String>[];

    for (final event in events) {
      final described = _describe(event);
      bool persisted;
      try {
        persisted = await _log.logEventOnceAt(
          described.level,
          described.message,
          dedupeKey: event.id,
          timestamp: event.at,
          source: logSource,
        );
      } catch (error, stackTrace) {
        _log.warning(
          '写入原生提醒事件失败',
          source: logSource,
          error: error,
          stackTrace: stackTrace,
        );
        persisted = false;
      }
      if (persisted) {
        confirmed.add(event.id);
        imported++;
      }
    }

    if (dropped > 0) {
      // 队列溢出会静默丢掉最旧的事件，这里必须留下痕迹。
      // 这条不做幂等，因为它描述的是「发生过溢出」而不是某个具体事件；
      // 确认时会把计数归零，所以正常情况下每次只会看到一条。
      _log.warning(
        '写日记提醒：原生事件队列溢出，已丢弃 $dropped 条最早的事件',
        source: logSource,
      );
    }

    try {
      await _channel.invokeMethod<void>('ack', <String, Object?>{
        'ids': confirmed,
      });
    } catch (error, stackTrace) {
      // 确认失败只会导致下次重复导入；重复导入被幂等键挡住，不会产生重复日志
      _log.warning(
        '确认原生提醒事件失败',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }

    return imported;
  }

  static ({List<DiaryReminderNativeEvent> events, int dropped}) _parsePayload(
    String? raw,
  ) {
    if (raw == null || raw.trim().isEmpty) {
      return (events: const <DiaryReminderNativeEvent>[], dropped: 0);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return (events: const <DiaryReminderNativeEvent>[], dropped: 0);
      }
      final events = <DiaryReminderNativeEvent>[];
      final rawEvents = decoded['events'];
      if (rawEvents is List) {
        for (final item in rawEvents) {
          final event = DiaryReminderNativeEvent.tryParse(item);
          if (event != null) events.add(event);
        }
      }
      final dropped = decoded['dropped'];
      return (
        events: events,
        dropped: dropped is int && dropped > 0 ? dropped : 0,
      );
    } on FormatException {
      return (events: const <DiaryReminderNativeEvent>[], dropped: 0);
    }
  }

  /// 事件码 → 日志级别与文案。刻意区分「已提交给系统」与「用户看到了」。
  static ({AppLogLevel level, String message}) _describe(
    DiaryReminderNativeEvent event,
  ) {
    // 原生侧不只埋写日记提醒，文案必须按 kind 区分，否则打卡的触发会被误标成写日记
    final label = _labelFor(event.kind);
    switch (event.code) {
      case 'receiver_fired':
        return (
          level: AppLogLevel.info,
          message: '$label：到点触发，原生接收器已运行',
        );
      case 'notify_returned':
        return (
          level: AppLogLevel.info,
          message: '$label：通知已提交给系统（不代表用户已看到）',
        );
      case 'notify_failed':
        return (
          level: AppLogLevel.error,
          message: '$label：提交通知失败（${_reason(event.detail)}）',
        );
      case 'next_schedule_attempt':
        return (
          level: AppLogLevel.info,
          message: '$label：开始登记下一次',
        );
      case 'next_schedule_returned':
        return (
          level: AppLogLevel.info,
          message: '$label：下一次已登记',
        );
      case 'next_schedule_failed':
        return (
          level: AppLogLevel.error,
          message: '$label：登记下一次失败（${_reason(event.detail)}），'
              '每天重复可能就此中断',
        );
      case 'boot_reschedule_attempt':
        return (
          level: AppLogLevel.info,
          message: '$label：开机后开始恢复排程',
        );
      case 'boot_reschedule_returned':
        return (
          level: AppLogLevel.info,
          message: '$label：开机后恢复排程成功',
        );
      case 'boot_reschedule_failed':
        return (
          level: AppLogLevel.error,
          message: '$label：开机后恢复排程失败（${_reason(event.detail)}）',
        );
      default:
        return (
          level: AppLogLevel.warning,
          message: '$label：收到未知原生事件 ${event.code}',
        );
    }
  }

  static String _labelFor(String? kind) {
    switch (kind) {
      case 'check_in_reminder':
        return '打卡提醒';
      case null:
      case 'diary_reminder':
        return '写日记提醒';
      default:
        return '提醒';
    }
  }

  static String _reason(String? detail) {
    switch (detail) {
      case null:
        return '原因未知';
      case 'exact_alarm_permission':
        return '缺少精确闹钟权限';
      case 'next_fire_date_null':
        return '无法计算下次触发时间';
      default:
        return detail;
    }
  }
}
