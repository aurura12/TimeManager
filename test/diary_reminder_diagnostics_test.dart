import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:time_manager/models/app_log_entry.dart';
import 'package:time_manager/services/app_log_service.dart';
import 'package:time_manager/services/app_log_store.dart';
import 'package:time_manager/services/diary_reminder_diagnostics.dart';
import 'package:time_manager/services/diary_reminder_service.dart';

/// 可切换失败状态的日志存储。既有 `FakeAppLogStore` 的标志位是 final，
/// 无法表达「先失败、再成功」，而重试路径正是这里要验证的。
class _FlakyLogStore implements AppLogStore {
  final List<String> lines = <String>[];
  bool failWrites = false;
  int rewriteCalls = 0;

  @override
  Future<List<String>> readLines() async => List<String>.of(lines);

  @override
  Future<void> appendLine(String line) async {
    if (failWrites) throw StateError('append failed');
    lines.add(line);
  }

  @override
  Future<void> rewriteLines(List<String> newLines) async {
    rewriteCalls++;
    if (failWrites) throw StateError('rewrite failed');
    lines
      ..clear()
      ..addAll(newLines);
  }

  @override
  Future<void> clear() async => lines.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(DiaryReminderDiagnostics.channelName);

  late _FlakyLogStore store;
  late AppLogService logService;
  late List<String> ackedIds;
  late int readPendingCalls;
  String? payload;

  /// 原生事件的发生时间（UTC）。
  final atFirst = DateTime.utc(2026, 9, 18, 13, 0, 1);
  final atSecond = DateTime.utc(2026, 9, 18, 13, 0, 2);

  String payloadWith(
    List<Map<String, Object?>> events, {
    int dropped = 0,
  }) {
    return jsonEncode(<String, Object?>{'dropped': dropped, 'events': events});
  }

  setUp(() async {
    store = _FlakyLogStore();
    logService = AppLogService(store: store, logger: Logger(level: Level.off));
    await logService.initialize();

    DiaryReminderDiagnostics.resetForTesting();
    DiaryReminderDiagnostics.logServiceOverride = logService;

    ackedIds = <String>[];
    readPendingCalls = 0;
    payload = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'readPending':
          readPendingCalls++;
          return payload;
        case 'ack':
          final arguments = call.arguments as Map<Object?, Object?>?;
          final ids = arguments?['ids'];
          if (ids is List) {
            ackedIds = ids.cast<String>();
          }
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    DiaryReminderDiagnostics.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('导入成功后按 ID 确认，日志用原生发生时间', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-1',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'receiver_fired',
      },
      <String, Object?>{
        'id': 'dr-2',
        'at': atSecond.millisecondsSinceEpoch,
        'code': 'notify_returned',
      },
    ]);

    final imported = await DiaryReminderDiagnostics.importPendingEvents();

    expect(imported, 2);
    expect(ackedIds, containsAll(<String>['dr-1', 'dr-2']));

    final entries = logService.entries;
    expect(entries, hasLength(2));
    for (final entry in entries) {
      expect(entry.source, DiaryReminderService.logSource);
      expect(entry.dedupeKey, isNotNull);
    }
    expect(
      entries.map((e) => e.timestamp).toSet(),
      <DateTime>{atFirst, atSecond},
      reason: '必须保留原生事件的发生时间，而不是导入时刻',
    );

    // 幂等键写进了 JSON，重启后才能识别出已经导入过
    expect(store.lines.any((line) => line.contains('dr-1')), isTrue);
  });

  test('阶段文案不把「已提交给系统」说成已送达', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-notify',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'notify_returned',
      },
      <String, Object?>{
        'id': 'dr-next',
        'at': atSecond.millisecondsSinceEpoch,
        'code': 'next_schedule_returned',
      },
    ]);

    await DiaryReminderDiagnostics.importPendingEvents();

    final messages = logService.entries.map((e) => e.message).toList();
    expect(
      messages.any((m) => m.contains('已提交给系统') && m.contains('不代表用户已看到')),
      isTrue,
    );
    expect(messages.any((m) => m.contains('下一次已登记')), isTrue);
  });

  test('失败事件记 error，并区分失败原因', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-fail',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'next_schedule_failed',
        'detail': 'exact_alarm_permission',
      },
    ]);

    await DiaryReminderDiagnostics.importPendingEvents();

    final entry = logService.entries.single;
    expect(entry.level, AppLogLevel.error);
    expect(entry.message, contains('缺少精确闹钟权限'));
    expect(entry.message, contains('每天重复可能就此中断'));
  });

  test('日志写入失败时不确认，事件留在原生队列等重试', () async {
    store.failWrites = true;
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-1',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'receiver_fired',
      },
    ]);

    final imported = await DiaryReminderDiagnostics.importPendingEvents();

    expect(imported, 0);
    expect(ackedIds, isEmpty, reason: '没落盘就不能删原生队列');
    expect(store.lines, isEmpty);
  });

  test('重试时先补做持久化，磁盘上只留一条', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-1',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'receiver_fired',
      },
    ]);

    store.failWrites = true;
    await DiaryReminderDiagnostics.importPendingEvents();
    expect(store.lines, isEmpty);

    // 恢复后重试：内存里已有这条，必须走整体重写而不是当成「已经确认成功」
    store.failWrites = false;
    final imported = await DiaryReminderDiagnostics.importPendingEvents();

    expect(imported, 1);
    expect(ackedIds, contains('dr-1'));
    expect(
      store.lines.where((line) => line.contains('dr-1')),
      hasLength(1),
      reason: '重写是幂等的，不允许出现重复行',
    );
    expect(logService.entries, hasLength(1));
  });

  test('重复导入同一事件不会产生第二条日志', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-1',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'receiver_fired',
      },
    ]);

    await DiaryReminderDiagnostics.importPendingEvents();
    // 第二次导入：事件仍在队列里（上次 ack 已被 mock 消费，这里模拟重发）
    final second = await DiaryReminderDiagnostics.importPendingEvents();

    // 计数会再记一次（它确实已经在磁盘上），但日志条目不重复
    expect(second, 1);
    expect(
      logService.entries.where((e) => e.dedupeKey == 'dr-1'),
      hasLength(1),
      reason: '幂等键必须挡住重复日志',
    );
    expect(
      store.lines.where((line) => line.contains('dr-1')),
      hasLength(1),
    );
  });

  test('队列溢出会留下一条 warning，不静默丢弃', () async {
    payload = payloadWith(
      <Map<String, Object?>>[
        <String, Object?>{
          'id': 'dr-1',
          'at': atFirst.millisecondsSinceEpoch,
          'code': 'receiver_fired',
        },
      ],
      dropped: 4,
    );

    await DiaryReminderDiagnostics.importPendingEvents();

    final warnings = logService.entries
        .where((e) => e.level == AppLogLevel.warning)
        .map((e) => e.message);
    expect(warnings.any((m) => m.contains('溢出') && m.contains('4')), isTrue);
  });

  test('按 kind 区分两类提醒的文案，不把打卡标成写日记', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-diary',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'receiver_fired',
        'kind': 'diary_reminder',
      },
      <String, Object?>{
        'id': 'dr-checkin',
        'at': atSecond.millisecondsSinceEpoch,
        'code': 'receiver_fired',
        'kind': 'check_in_reminder',
      },
    ]);

    await DiaryReminderDiagnostics.importPendingEvents();

    final messages = logService.entries.map((e) => e.message).toList();
    expect(messages.any((m) => m.startsWith('写日记提醒：')), isTrue);
    expect(messages.any((m) => m.startsWith('打卡提醒：')), isTrue);
    expect(
      messages.where((m) => m.contains('打卡提醒：到点触发')),
      hasLength(1),
    );
  });

  test('缺少 kind 字段时按写日记提醒处理（兼容旧埋点）', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-legacy',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'receiver_fired',
      },
    ]);

    await DiaryReminderDiagnostics.importPendingEvents();

    expect(logService.entries.single.message, startsWith('写日记提醒：'));
  });

  test('未知事件码记 warning，不会崩', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-x',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'brand_new_code',
      },
    ]);

    await DiaryReminderDiagnostics.importPendingEvents();

    expect(logService.entries.single.level, AppLogLevel.warning);
    expect(logService.entries.single.message, contains('未知原生事件'));
  });

  test('冷启动与 resume 同时导入只执行一次读写事务', () async {
    payload = payloadWith(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'dr-1',
        'at': atFirst.millisecondsSinceEpoch,
        'code': 'receiver_fired',
      },
    ]);

    final results = await Future.wait<int>(<Future<int>>[
      DiaryReminderDiagnostics.importPendingEvents(),
      DiaryReminderDiagnostics.importPendingEvents(),
    ]);

    expect(readPendingCalls, 1, reason: 'single-flight 必须只读一次队列');
    expect(results, <int>[1, 1]);
    expect(ackedIds, <String>['dr-1']);
  });

  test('缺少原生通道（桌面端）时静默跳过，不抛异常', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    final imported = await DiaryReminderDiagnostics.importPendingEvents();

    expect(imported, 0);
    expect(logService.entries, isEmpty);
  });

  test('空队列不做任何写入', () async {
    payload = payloadWith(<Map<String, Object?>>[]);

    final imported = await DiaryReminderDiagnostics.importPendingEvents();

    expect(imported, 0);
    expect(logService.entries, isEmpty);
    expect(ackedIds, isEmpty);
  });
}
