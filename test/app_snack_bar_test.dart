import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/services/app_identity_service.dart';
import 'package:time_manager/utils/app_snack_bar.dart';
import 'package:time_manager/utils/confirm_dialog.dart';

Future<void> _pumpHost(
  WidgetTester tester, {
  required WidgetBuilder builder,
}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: builder))));
  await tester.pump();
}

/// 在二级页面里构建内容：用于验证「页面关闭后提示条仍然可点」。
Future<void> _pumpHostWithPush(
  WidgetTester tester,
  WidgetBuilder builder,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (pageContext) => Scaffold(
                    body: Center(child: Builder(builder: builder)),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    AppIdentityService.resetForTesting();
  });

  tearDown(() {
    AppIdentityService.resetForTesting();
  });

  testWidgets('showAppSnackBar 顶掉当前 SnackBar 并显示新消息', (tester) async {
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: Column(
          children: [
            TextButton(
              onPressed: () => showAppSnackBar(context, '第一条'),
              child: const Text('first'),
            ),
            TextButton(
              onPressed: () => showAppSnackBar(context, '第二条'),
              child: const Text('second'),
            ),
          ],
        ),
      );
    });

    await tester.tap(find.text('first'));
    await tester.pump();
    expect(find.text('第一条'), findsOneWidget);

    await tester.tap(find.text('second'));
    await tester.pump();
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);
  });

  testWidgets('showAppUndoSnackBar 点击撤销执行回调', (tester) async {
    var undoCount = 0;
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: TextButton(
          onPressed: () => showAppUndoSnackBar(
            context,
            message: '已删除',
            onUndo: () async => undoCount++,
          ),
          child: const Text('delete'),
        ),
      );
    });

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('已删除'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pump();
    expect(undoCount, 1);
  });

  testWidgets('身份不匹配时撤销被拒绝', (tester) async {
    AppIdentityService.adoptManualKind(DiaryKind.g);
    var undoCount = 0;
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: TextButton(
          onPressed: () => showAppUndoSnackBar(
            context,
            message: '已删除',
            identityToken: AppIdentityService.identityStamp,
            onUndo: () async => undoCount++,
          ),
          child: const Text('delete'),
        ),
      );
    });

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('已删除'), findsOneWidget);

    // 模拟切换身份后再点撤销。
    AppIdentityService.adoptManualKind(DiaryKind.j);
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(undoCount, 0);
    expect(find.text('身份已切换，撤销已失效'), findsOneWidget);
  });

  testWidgets('撤销回调抛异常时提示失败且不崩溃', (tester) async {
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: TextButton(
          onPressed: () => showAppUndoSnackBar(
            context,
            message: '已删除',
            onUndo: () async => throw StateError('boom'),
          ),
          child: const Text('delete'),
        ),
      );
    });

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('撤销失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展示提示条的页面关闭后，撤销仍然生效', (tester) async {
    var undoCount = 0;
    await _pumpHostWithPush(tester, (pageContext) {
      return TextButton(
        onPressed: () {
          showAppUndoSnackBar(
            pageContext,
            message: '已删除目标',
            onUndo: () async => undoCount++,
          );
          Navigator.of(pageContext).pop();
        },
        child: const Text('delete'),
      );
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();

    // SnackBar 挂在 ScaffoldMessenger 上，页面关闭后仍然可见可点。
    expect(find.text('已删除目标'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(undoCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面关闭后身份已切换，撤销被拒绝且不崩溃', (tester) async {
    AppIdentityService.adoptManualKind(DiaryKind.g);
    var undoCount = 0;
    await _pumpHostWithPush(tester, (pageContext) {
      return TextButton(
        onPressed: () {
          showAppUndoSnackBar(
            pageContext,
            message: '已删除目标',
            identityToken: AppIdentityService.identityStamp,
            onUndo: () async => undoCount++,
          );
          Navigator.of(pageContext).pop();
        },
        child: const Text('delete'),
      );
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();

    AppIdentityService.adoptManualKind(DiaryKind.j);
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(undoCount, 0);
    expect(find.text('身份已切换，撤销已失效'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showConfirmDialog destructive 样式返回用户选择', (tester) async {
    var confirmed = false;
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: TextButton(
          onPressed: () async {
            confirmed = await showConfirmDialog(
              context,
              title: '删除确认',
              message: '确认删除吗？',
              confirmLabel: '删除',
              destructive: true,
            );
          },
          child: const Text('open'),
        ),
      );
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('删除确认'), findsOneWidget);

    // FilledButton 使用 error 配色（destructive）。
    final button = find.ancestor(
      of: find.text('删除'),
      matching: find.byType(FilledButton),
    );
    expect(button, findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('showConfirmDialog 取消返回 false', (tester) async {
    var confirmed = true;
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: TextButton(
          onPressed: () async {
            confirmed = await showConfirmDialog(
              context,
              title: '删除确认',
              message: '确认删除吗？',
            );
          },
          child: const Text('open'),
        ),
      );
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);
  });
}
