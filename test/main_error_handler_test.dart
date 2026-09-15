import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/main.dart';
import 'package:time_manager/models/app_log_entry.dart';
import 'package:time_manager/services/app_log_service.dart';

import 'support/fake_app_log_store.dart';

void main() {
  test('全局 Flutter 和 Dart 错误处理器会写入应用日志', () {
    final service = AppLogService(store: FakeAppLogStore());
    final previousFlutterHandler = FlutterError.onError;
    final previousPlatformHandler = PlatformDispatcher.instance.onError;
    try {
      installGlobalLogErrorHandlers(service);

      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('widget failed'),
        stack: StackTrace.current,
      ));
      final handled = PlatformDispatcher.instance.onError!(
        StateError('async failed'),
        StackTrace.current,
      );

      expect(handled, isFalse);
      expect(service.entries, hasLength(2));
      expect(service.entries[0].source, 'dart');
      expect(service.entries[0].level, AppLogLevel.error);
      expect(service.entries[1].source, 'flutter');
      expect(service.entries[1].level, AppLogLevel.error);
      expect(service.entries[0].message, contains('DART-'));
      expect(service.entries[1].message, contains('UI-'));
    } finally {
      FlutterError.onError = previousFlutterHandler;
      PlatformDispatcher.instance.onError = previousPlatformHandler;
    }
  });

  test('错误编号短且可检索，但不会把异常内容直接编码到页面', () {
    const rawError = 'response body: 用户的日记内容 /Users/mac/private/diary.json';
    final stackTrace = StackTrace.fromString(
      '#0      /Users/mac/project/TimeManager/lib/private.dart:42:7',
    );

    final code = buildErrorReferenceCode(
      scope: 'ui render',
      error: StateError(rawError),
      stackTrace: stackTrace,
    );

    expect(code, matches(RegExp(r'^UIRENDER-[0-9A-F]{8}$')));
    expect(code, isNot(contains(rawError)));
    expect(code, isNot(contains('/Users/mac')));
    expect(
      code,
      buildErrorReferenceCode(
        scope: 'ui render',
        error: StateError(rawError),
        stackTrace: stackTrace,
      ),
    );
    expect(
      normalizeErrorReferenceCode('/Users/mac/private/diary.json'),
      'ERR-00000000',
    );
  });

  testWidgets('错误页只展示固定文案和安全错误编号', (tester) async {
    final controller = AppRecoveryController();
    addTearDown(controller.dispose);
    const rawError = 'response body: 用户的日记内容 /Users/mac/private/diary.json';
    const code = 'UI-1234ABCD';

    await tester.pumpWidget(
      MaterialApp(
        home: SafeErrorPage(
          kind: SafeErrorPageKind.render,
          errorCode: code,
          onReload: controller.reloadCurrentInterface,
        ),
      ),
    );

    expect(find.text(safeErrorTitle(SafeErrorPageKind.render)), findsOneWidget);
    expect(
      find.text(safeErrorDescription(SafeErrorPageKind.render)),
      findsOneWidget,
    );
    expect(find.text('错误编号：$code'), findsOneWidget);
    expect(find.textContaining(rawError), findsNothing);
    expect(find.textContaining('/Users/mac'), findsNothing);

    await tester.tap(find.text('重新加载当前界面'));
    expect(controller.value, 1);
  });

  testWidgets('启动失败页不展示原始异常或堆栈', (tester) async {
    final controller = AppRecoveryController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SafeErrorPage(
          kind: SafeErrorPageKind.startup,
          errorCode: 'STARTUP-89ABCDEF',
          onReload: controller.reloadCurrentInterface,
        ),
      ),
    );

    expect(
      find.text(safeErrorTitle(SafeErrorPageKind.startup)),
      findsOneWidget,
    );
    expect(find.text('启动失败: /Users/mac/private/app.json'), findsNothing);
    expect(find.textContaining('#0'), findsNothing);
    expect(find.text('错误编号：STARTUP-89ABCDEF'), findsOneWidget);
  });

  testWidgets('重新加载只重建当前界面子树，不重新创建控制器', (tester) async {
    final controller = AppRecoveryController();
    addTearDown(controller.dispose);
    var buildCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: AppRecoveryBoundary(
          controller: controller,
          child: Builder(
            builder: (context) {
              buildCount++;
              return Text('build-$buildCount');
            },
          ),
        ),
      ),
    );
    final initialBuildCount = buildCount;

    controller.reloadCurrentInterface();
    await tester.pump();

    expect(buildCount, greaterThan(initialBuildCount));
    expect(controller.value, 1);
  });

  testWidgets('ErrorWidget builder 将详细异常交给日志，但页面不显示详情', (tester) async {
    final service = AppLogService(store: FakeAppLogStore());
    final controller = AppRecoveryController();
    addTearDown(controller.dispose);
    final previousBuilder = ErrorWidget.builder;
    const rawError = 'response body: 业务数据 /Users/mac/private/response.json';
    final details = FlutterErrorDetails(
      exception: StateError(rawError),
      stack: StackTrace.fromString(
        '#0      /Users/mac/project/TimeManager/lib/secret.dart:9:3',
      ),
    );

    try {
      installSafeErrorWidgetBuilder(
        service: service,
        recoveryController: controller,
      );
      final safePage = ErrorWidget.builder(details);
      await tester.pumpWidget(MaterialApp(home: safePage));

      expect(find.textContaining(rawError), findsNothing);
      expect(find.textContaining('/Users/mac'), findsNothing);
      expect(service.entries, hasLength(1));
      expect(
        service.entries.single.message,
        contains(
          buildErrorReferenceCode(
            scope: 'UI',
            error: details.exception,
            stackTrace: details.stack,
          ),
        ),
      );
      expect(service.entries.single.error, contains(rawError));
    } finally {
      ErrorWidget.builder = previousBuilder;
    }
  });

  testWidgets('错误页可返回上一页', (tester) async {
    final controller = AppRecoveryController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SafeErrorPage(
                    kind: SafeErrorPageKind.render,
                    errorCode: 'UI-1234ABCD',
                    onReload: controller.reloadCurrentInterface,
                  ),
                ),
              );
            },
            child: const Text('打开错误页'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开错误页'));
    await tester.pumpAndSettle();
    expect(find.text('返回上一页'), findsOneWidget);

    await tester.tap(find.text('返回上一页'));
    await tester.pumpAndSettle();
    expect(find.text('打开错误页'), findsOneWidget);
  });
}
