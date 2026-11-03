import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/widgets/motion_transitions.dart';

/// 最小宿主：不引入 MaterialApp / 路由，避免框架自带的转场混进断言。
Widget _host(Widget child, {bool disableAnimations = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  );
}

double _fadeOpacity(WidgetTester tester) {
  final fade = tester.widget<FadeTransition>(find.byType(FadeTransition));
  return fade.opacity.value;
}

void main() {
  test('转场时长落在 160–200ms 且带曲线', () {
    expect(AppMotion.transition.inMilliseconds, inInclusiveRange(160, 200));
    expect(AppMotion.curve, isNotNull);
    expect(AppMotion.listEnterOffset, greaterThan(0));
  });

  group('ValueChangeTransition', () {
    testWidgets('值变化时淡入，值不变不重播', (tester) async {
      await tester.pumpWidget(
        _host(const ValueChangeTransition(value: 1, child: SizedBox())),
      );
      expect(_fadeOpacity(tester), 1);

      await tester.pumpWidget(
        _host(const ValueChangeTransition(value: 2, child: SizedBox())),
      );
      expect(_fadeOpacity(tester), lessThan(1));

      await tester.pumpAndSettle();
      expect(_fadeOpacity(tester), 1);

      // 同一 value 下的普通重建（例如编辑时间块触发的 setState）不再播。
      await tester.pumpWidget(
        _host(const ValueChangeTransition(value: 2, child: SizedBox(width: 4))),
      );
      expect(_fadeOpacity(tester), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('系统关闭动画时直接到位', (tester) async {
      await tester.pumpWidget(_host(
        const ValueChangeTransition(value: 1, child: SizedBox()),
        disableAnimations: true,
      ));
      await tester.pumpWidget(_host(
        const ValueChangeTransition(value: 2, child: SizedBox()),
        disableAnimations: true,
      ));
      expect(_fadeOpacity(tester), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('ListItemRemoval', () {
    Widget host(bool removing, VoidCallback onCollapsed) {
      return _host(Center(
        child: SizedBox(
          width: 240,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListItemRemoval(
                removing: removing,
                onCollapsed: onCollapsed,
                child: const SizedBox(height: 120, child: Text('一行')),
              ),
            ],
          ),
        ),
      ));
    }

    testWidgets('先收高淡出，塌到 0 才回调删除', (tester) async {
      var collapsed = 0;
      await tester.pumpWidget(host(false, () => collapsed++));
      expect(tester.getSize(find.byType(ListItemRemoval)).height, 120);

      await tester.pumpWidget(host(true, () => collapsed++));
      await tester.pump(const Duration(milliseconds: 90));
      final midHeight = tester.getSize(find.byType(ListItemRemoval)).height;
      expect(midHeight, greaterThan(0));
      expect(midHeight, lessThan(120));
      expect(collapsed, 0);

      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ListItemRemoval)).height, 0);
      expect(collapsed, 1);
    });

    testWidgets('收高期间不吃点击，回落时高度长回去', (tester) async {
      var tapped = 0;
      Widget build(bool removing) => _host(Center(
            child: SizedBox(
              width: 240,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListItemRemoval(
                  removing: removing,
                  onCollapsed: () {},
                  child: GestureDetector(
                    onTap: () => tapped++,
                    child: const SizedBox(height: 120, child: Text('一行')),
                  ),
                ),
              ]),
            ),
          ));

      await tester.pumpWidget(build(false));
      await tester.tap(find.text('一行'));
      expect(tapped, 1);

      await tester.pumpWidget(build(true));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('一行'), warnIfMissed: false);
      expect(tapped, 1);

      // 删除被回滚：标记置空，高度自己长回来。
      await tester.pumpWidget(build(false));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ListItemRemoval)).height, 120);
    });

    testWidgets('系统关闭动画时一帧内完成', (tester) async {
      var collapsed = 0;
      Widget build(bool removing) => _host(
            Center(
              child: SizedBox(
                width: 240,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ListItemRemoval(
                    removing: removing,
                    onCollapsed: () => collapsed++,
                    child: const SizedBox(height: 120, child: Text('一行')),
                  ),
                ]),
              ),
            ),
            disableAnimations: true,
          );

      await tester.pumpWidget(build(false));
      await tester.pumpWidget(build(true));
      await tester.pump();
      expect(tester.getSize(find.byType(ListItemRemoval)).height, 0);
      expect(collapsed, 1);
    });
  });

  group('ListItemEntrance', () {
    testWidgets('只有标记为新增的条目播放入场', (tester) async {
      var ended = 0;
      Widget build(bool playing) => _host(ListItemEntrance(
            playing: playing,
            onEnd: () => ended++,
            child: const SizedBox(width: 120, height: 60),
          ));

      await tester.pumpWidget(build(false));
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
      expect(ended, 0);

      await tester.pumpWidget(build(true));
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, lessThan(1));
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
      expect(ended, 1);
    });

    testWidgets('系统关闭动画时直接显示并回调', (tester) async {
      var ended = 0;
      await tester.pumpWidget(_host(
        ListItemEntrance(
          playing: true,
          onEnd: () => ended++,
          child: const SizedBox(width: 120, height: 60),
        ),
        disableAnimations: true,
      ));
      await tester.pump();
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
      expect(ended, 1);
    });
  });

  group('动效源码守卫', () {
    test('页面层不得自己搭转场，统一走 widgets/motion_transitions.dart', () {
      final banned = RegExp(
        r'\b(AnimatedSwitcher|FadeTransition|SlideTransition|SizeTransition|TweenAnimationBuilder)\b'
        r'|AnimationController\s*\(',
      );
      final violations = <String>[];
      for (final entity in Directory('lib/screens').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        final lines = entity.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (banned.hasMatch(lines[i])) {
            violations.add('$path:${i + 1}  ${lines[i].trim()}');
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason: '页面需要过渡时用 ValueChangeTransition / ListItemEntrance / '
            'ListItemRemoval；确需例外请在测试里写白名单并说明理由。',
      );
    });
  });
}
