import 'dart:io';

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

/// 让提示条走完「计时器到期 + 退场动画」。
///
/// SnackBar 的停留计时器在入场动画结束后的那次 build 里才创建，所以先要
/// pumpAndSettle 走完入场，再越过 duration 才会触发 hide。
Future<void> _elapseSnackBar(WidgetTester tester, Duration duration) async {
  await tester.pump(duration + const Duration(seconds: 1));
  await tester.pumpAndSettle();
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

  testWidgets('duration 只影响这一条提示的停留时间', (tester) async {
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: Column(
          children: [
            TextButton(
              onPressed: () => showAppSnackBar(
                context,
                '短提示',
                duration: const Duration(seconds: 2),
              ),
              child: const Text('short'),
            ),
            TextButton(
              onPressed: () => showAppSnackBar(context, '默认提示'),
              child: const Text('default'),
            ),
          ],
        ),
      );
    });

    await tester.tap(find.text('short'));
    await tester.pumpAndSettle();
    expect(find.text('短提示'), findsOneWidget);

    await _elapseSnackBar(tester, const Duration(seconds: 2));
    expect(find.text('短提示'), findsNothing);

    await tester.tap(find.text('default'));
    await tester.pumpAndSettle();
    expect(find.text('默认提示'), findsOneWidget);

    // 默认时长更长：2 秒时还在。
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('默认提示'), findsOneWidget);

    await _elapseSnackBar(tester, const Duration(seconds: 2));
    expect(find.text('默认提示'), findsNothing);
  });

  testWidgets('showAppSnackBarOn 传入 null 时静默不抛', (tester) async {
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: TextButton(
          onPressed: () => showAppSnackBarOn(null, '不会出现'),
          child: const Text('fire'),
        ),
      );
    });

    await tester.tap(find.text('fire'));
    await tester.pump();
    expect(find.text('不会出现'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showAppSnackBarOn 用提前抓的 messenger 跨页面展示', (tester) async {
    ScaffoldMessengerState? messenger;
    await _pumpHostWithPush(tester, (pageContext) {
      return TextButton(
        onPressed: () {
          messenger = ScaffoldMessenger.of(pageContext);
          Navigator.of(pageContext).pop();
        },
        child: const Text('grab'),
      );
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('grab'));
    await tester.pumpAndSettle();

    showAppSnackBarOn(messenger, '跨页面提示');
    await tester.pump();
    expect(find.text('跨页面提示'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('撤销窗口内普通提示排队，不顶掉撤销按钮', (tester) async {
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: Column(
          children: [
            TextButton(
              onPressed: () => showAppUndoSnackBar(
                context,
                message: '已删除',
                onUndo: () async {},
              ),
              child: const Text('delete'),
            ),
            TextButton(
              onPressed: () => showAppSnackBar(context, '同步失败'),
              child: const Text('plain'),
            ),
          ],
        ),
      );
    });

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('撤销'), findsOneWidget);

    await tester.tap(find.text('plain'));
    await tester.pump();
    // 撤销窗口还有效：撤销按钮仍在，普通提示先不出现。
    expect(find.text('撤销'), findsOneWidget);
    expect(find.text('同步失败'), findsNothing);

    // 撤销条自己超时后，待发的普通提示才出现。
    await _elapseSnackBar(tester, appUndoSnackBarDuration);
    expect(find.text('撤销'), findsNothing);
    expect(find.text('同步失败'), findsOneWidget);
  });

  testWidgets('撤销窗口内连发多条只保留最新一条', (tester) async {
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: Column(
          children: [
            TextButton(
              onPressed: () => showAppUndoSnackBar(
                context,
                message: '已删除',
                onUndo: () async {},
              ),
              child: const Text('delete'),
            ),
            TextButton(
              onPressed: () {
                showAppSnackBar(context, '第一条');
                showAppSnackBar(context, '第二条');
                showAppSnackBar(context, '第三条');
              },
              child: const Text('plain'),
            ),
          ],
        ),
      );
    });

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('plain'));
    await tester.pump();
    expect(find.text('第一条'), findsNothing);

    await _elapseSnackBar(tester, appUndoSnackBarDuration);
    expect(find.text('第三条'), findsOneWidget);
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsNothing);
  });

  testWidgets('点撤销后撤销窗口立即结束，普通提示不再排队', (tester) async {
    var undoCount = 0;
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: Column(
          children: [
            TextButton(
              onPressed: () => showAppUndoSnackBar(
                context,
                message: '已删除',
                onUndo: () async => undoCount++,
              ),
              child: const Text('delete'),
            ),
            TextButton(
              onPressed: () => showAppSnackBar(context, '同步失败'),
              child: const Text('plain'),
            ),
          ],
        ),
      );
    });

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(undoCount, 1);

    await tester.tap(find.text('plain'));
    await tester.pump();
    expect(find.text('同步失败'), findsOneWidget);
  });

  testWidgets('interruptUndo 立刻顶掉撤销条', (tester) async {
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: Column(
          children: [
            TextButton(
              onPressed: () => showAppUndoSnackBar(
                context,
                message: '已删除',
                onUndo: () async {},
              ),
              child: const Text('delete'),
            ),
            TextButton(
              onPressed: () => showAppSnackBar(
                context,
                '保存失败',
                interruptUndo: true,
              ),
              child: const Text('urgent'),
            ),
          ],
        ),
      );
    });

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('撤销'), findsOneWidget);

    await tester.tap(find.text('urgent'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败'), findsOneWidget);
    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('clearAppSnackBars 连待发消息一起清掉', (tester) async {
    await _pumpHost(tester, builder: (context) {
      return Center(
        child: Column(
          children: [
            TextButton(
              onPressed: () => showAppUndoSnackBar(
                context,
                message: '已删除',
                onUndo: () async {},
              ),
              child: const Text('delete'),
            ),
            TextButton(
              onPressed: () => showAppSnackBar(context, '切换后的提示'),
              child: const Text('plain'),
            ),
            TextButton(
              onPressed: () => clearAppSnackBars(ScaffoldMessenger.of(context)),
              child: const Text('clear'),
            ),
          ],
        ),
      );
    });

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('plain'));
    await tester.pump();
    expect(find.text('切换后的提示'), findsNothing);

    await tester.tap(find.text('clear'));
    await tester.pumpAndSettle();
    expect(find.text('撤销'), findsNothing);

    // 撤销窗口曾经结束，也不会把待发消息补出来。
    await tester.pump(appUndoSnackBarDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('切换后的提示'), findsNothing);
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

  test('lib 下只有提示条 helper 允许直接调用 showSnackBar', () {
    // 页面各自搭 SnackBar 会让「顶掉式」与撤销窗口保护失效，
    // 这里守住入口：新提示一律走 showAppSnackBar / showAppSnackBarOn。
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('lib/utils/app_snack_bar.dart')) continue;
      if (entity.readAsStringSync().contains('showSnackBar(')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty, reason: '这些文件还直接调用了 showSnackBar');
  });
}
