import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/widgets/day_change_boundary.dart';
import 'package:time_manager/widgets/main_tab_activity.dart';

Widget _page({
  required DateTime Function() clock,
  required void Function(DateTime, DateTime) onDayChanged,
  bool active = true,
  bool ready = true,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MainTabActivity(
      isActive: active,
      child: DayChangeBoundary(
        clock: clock,
        onDayChanged: onDayChanged,
        canHandleDayChange: () => ready,
        builder: (_) => Text('第${clock().day}天'),
      ),
    ),
  );
}

void main() {
  testWidgets('跨午夜只通知一次，并重建内容', (tester) async {
    var clock = DateTime(2026, 10, 6, 23, 59, 59);
    final changes = <String>[];
    await tester.pumpWidget(_page(
      clock: () => clock,
      onDayChanged: (previous, today) =>
          changes.add('${previous.day}->${today.day}'),
    ));

    expect(find.text('第6天'), findsOneWidget);
    expect(changes, isEmpty);

    clock = DateTime(2026, 10, 7, 0, 0, 1);
    await tester.pump(const Duration(seconds: 2));

    expect(changes, ['6->7']);
    expect(find.text('第7天'), findsOneWidget);

    // 同一天内不会重复通知
    clock = DateTime(2026, 10, 7, 12);
    await tester.pump(const Duration(hours: 12));
    expect(changes, ['6->7']);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('隐藏页面暂停，重新可见后补发跨日通知', (tester) async {
    var clock = DateTime(2026, 10, 6, 23, 59, 59);
    var active = true;
    final changes = <String>[];

    Widget page() => _page(
          clock: () => clock,
          active: active,
          onDayChanged: (previous, today) =>
              changes.add('${previous.day}->${today.day}'),
        );

    await tester.pumpWidget(page());
    active = false;
    await tester.pumpWidget(page());

    clock = DateTime(2026, 10, 7, 8);
    await tester.pump(const Duration(days: 1));
    expect(changes, isEmpty);

    active = true;
    await tester.pumpWidget(page());
    expect(changes, ['6->7']);
    expect(find.text('第7天'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('后台跨日，回到前台后补发一次', (tester) async {
    var clock = DateTime(2026, 10, 6, 23, 59, 59);
    final changes = <String>[];

    await tester.pumpWidget(_page(
      clock: () => clock,
      onDayChanged: (previous, today) =>
          changes.add('${previous.day}->${today.day}'),
    ));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    clock = DateTime(2026, 10, 7, 9);
    await tester.pump(const Duration(days: 1));
    expect(changes, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(changes, ['6->7']);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('页面忙碌时保留跨日，结束后补发一次', (tester) async {
    var clock = DateTime(2026, 10, 6, 23, 59, 59);
    var ready = false;
    final changes = <String>[];
    Widget page() => _page(
          clock: () => clock,
          ready: ready,
          onDayChanged: (previous, today) =>
              changes.add('${previous.day}->${today.day}'),
        );

    await tester.pumpWidget(page());
    clock = DateTime(2026, 10, 7, 0, 0, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(changes, isEmpty);

    ready = true;
    await tester.pumpWidget(page());
    await tester.pump();
    expect(changes, ['6->7']);
    await tester.pumpWidget(page());
    await tester.pump();
    expect(changes, ['6->7']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('忙碌跨过多天后仍从原来的今天补发', (tester) async {
    var clock = DateTime(2026, 10, 6, 23, 59, 59);
    var ready = false;
    var active = true;
    final changes = <String>[];
    Widget page() => _page(
          clock: () => clock,
          active: active,
          ready: ready,
          onDayChanged: (previous, today) =>
              changes.add('${previous.day}->${today.day}'),
        );

    await tester.pumpWidget(page());
    clock = DateTime(2026, 10, 7, 0, 0, 1);
    await tester.pump(const Duration(seconds: 2));
    active = false;
    await tester.pumpWidget(page());
    clock = DateTime(2026, 10, 9, 8);
    ready = true;
    await tester.pumpWidget(page());
    expect(changes, isEmpty);
    active = true;
    await tester.pumpWidget(page());
    await tester.pump();
    expect(changes, ['6->9']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('后台结束忙碌时等回前台再补发跨日', (tester) async {
    var clock = DateTime(2026, 10, 6, 23, 59, 59);
    var ready = false;
    final changes = <String>[];
    Widget page() => _page(
          clock: () => clock,
          ready: ready,
          onDayChanged: (previous, today) =>
              changes.add('${previous.day}->${today.day}'),
        );

    await tester.pumpWidget(page());
    clock = DateTime(2026, 10, 7, 0, 0, 1);
    await tester.pump(const Duration(seconds: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    ready = true;
    await tester.pumpWidget(page());
    await tester.pump();
    expect(changes, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(changes, ['6->7']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
