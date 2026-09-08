import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/app_log_entry.dart';
import 'package:time_manager/services/app_log_service.dart';

import 'support/fake_app_log_store.dart';

void main() {
  test('初始化会跳过坏行并合并初始化前暂存的日志', () async {
    final store = FakeAppLogStore(lines: [
      jsonEncode(AppLogEntry(
        timestamp: DateTime.utc(2026, 9, 8, 8),
        level: AppLogLevel.info,
        source: 'test',
        message: '已存在',
      ).toJson()),
      '{bad json',
    ]);
    final service = AppLogService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 8, 9),
    );

    service.info('初始化前记录', source: 'startup');
    await service.initialize();

    expect(service.entries.map((entry) => entry.message), [
      '初始化前记录',
      '已存在',
    ]);
  });

  test('日志最多保留最近 2000 条并淘汰最旧条目', () async {
    final service = AppLogService(
      store: FakeAppLogStore(),
      clock: () => DateTime.utc(2026, 9, 8),
    );
    await service.initialize();

    for (var i = 0; i < 2001; i++) {
      service.info('日志 $i', source: 'test');
    }
    await service.flush();

    expect(service.entries, hasLength(2000));
    expect(service.entries.first.message, '日志 2000');
    expect(service.entries.last.message, '日志 1');
  });

  test('达到上限时先重写裁剪，不会先把第 2001 条追加到磁盘', () async {
    final store = FakeAppLogStore(
      lines: List<String>.generate(
        2000,
        (index) => jsonEncode(
          AppLogEntry(
            timestamp: DateTime.utc(2026, 9, 8).add(Duration(seconds: index)),
            level: AppLogLevel.info,
            source: 'test',
            message: '旧日志 $index',
          ).toJson(),
        ),
      ),
      throwOnRewrite: true,
    );
    final service = AppLogService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 10),
    );
    await service.initialize();

    service.info('新日志', source: 'test');
    await service.flush();

    expect(store.lines, hasLength(2000));
    expect(service.entries.first.message, '新日志');
  });

  test('日志会脱敏明显的认证字段且持久化失败不向调用方抛异常', () async {
    final service = AppLogService(
      store: FakeAppLogStore(throwOnWrite: true),
      clock: () => DateTime.utc(2026, 9, 8),
    );
    await service.initialize();

    expect(
      () => service.error(
        '请求失败 token=secret-value',
        source: 'test',
        error: 'authorization: Bearer secret-token',
      ),
      returnsNormally,
    );
    await service.flush();

    expect(service.entries.single.message, isNot(contains('secret-value')));
    expect(service.entries.single.error, isNot(contains('secret-token')));
  });

  test('加载旧日志时也会脱敏并严格限制字段长度', () async {
    final store = FakeAppLogStore(
      lines: [
        jsonEncode(
          AppLogEntry(
            timestamp: DateTime.utc(2026, 9, 8),
            level: AppLogLevel.error,
            source: 'source ${'s' * 500}',
            message: 'id_token=old-secret ${'m' * 5000}',
            error: 'client_secret=client-secret cookie=cookie-secret',
            stackTrace: 'cookie: stack-cookie ${'t' * 13000}',
          ).toJson(),
        ),
      ],
    );
    final service = AppLogService(store: store);

    await service.initialize();

    final entry = service.entries.single;
    expect(entry.source.length, lessThanOrEqualTo(120));
    expect(entry.message.length, lessThanOrEqualTo(4096));
    expect(entry.message, isNot(contains('old-secret')));
    expect(entry.error, isNot(contains('client-secret')));
    expect(entry.error, isNot(contains('cookie-secret')));
    expect(entry.stackTrace, isNot(contains('stack-cookie')));
    expect(entry.stackTrace!.length, lessThanOrEqualTo(12000));
    expect(store.lines.single, isNot(contains('old-secret')));
    expect(store.lines.single, isNot(contains('client-secret')));
  });

  test('clear 会立即清空内存并清除存储', () async {
    final store = FakeAppLogStore();
    final service = AppLogService(store: store);
    await service.initialize();
    service.info('待清除', source: 'test');
    await service.clear();

    expect(service.entries, isEmpty);
    expect(store.lines, isEmpty);
  });
}
