import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/utils/menu_bar_dial_position.dart';

/// 面板内容区 368×570（400 宽窗口减左右 16、高度减头部/提示/底栏）。
const Size _bounds = Size(368, 570);
const Size _dial = Size(264, 308);

MenuBarDialPlacement _place(Rect selection, {Size bounds = _bounds}) =>
    placeMenuBarDial(selection: selection, bounds: bounds, dialSize: _dial);

void main() {
  group('placeMenuBarDial', () {
    test('右侧放得下就贴右边并垂直居中', () {
      final placement = _place(const Rect.fromLTWH(8, 200, 60, 45));
      expect(placement.side, MenuBarDialSide.right);
      expect(placement.rect.left, closeTo(8 + 60 + 8, 1e-9));
      expect(placement.rect.center.dy, closeTo(222.5, 1e-9));
      expect(placement.overlapsSelection, isFalse);
    });

    test('右边放不下就翻到左边', () {
      // 第 5 列（16:50 起）右侧只剩 0pt，左侧还够。
      final placement = _place(const Rect.fromLTWH(316, 200, 44, 45));
      expect(placement.side, MenuBarDialSide.left);
      expect(placement.rect.left, closeTo(316 - 8 - 264, 1e-9));
      expect(placement.overlapsSelection, isFalse);
    });

    test('左右都放不下时落到选区下方', () {
      final placement = _place(const Rect.fromLTWH(56, 51, 102, 43));
      expect(placement.side, MenuBarDialSide.below);
      expect(placement.rect.top, closeTo(51 + 43 + 8, 1e-9));
      expect(placement.rect.left, closeTo(8, 1e-9)); // 居中后夹到左边距
      expect(placement.overlapsSelection, isFalse);
    });

    test('下方不够就翻到上方', () {
      final placement = _place(const Rect.fromLTWH(56, 414, 102, 43));
      expect(placement.side, MenuBarDialSide.above);
      expect(placement.rect.bottom, closeTo(414 - 8, 1e-9));
      expect(placement.overlapsSelection, isFalse);
    });

    test('四面都挤不下时夹进边界并允许压住选区', () {
      final placement = _place(const Rect.fromLTWH(56, 322, 102, 43));
      expect(placement.side, MenuBarDialSide.clamped);
      expect(placement.rect.right, lessThanOrEqualTo(_bounds.width - 8));
      expect(placement.rect.bottom, lessThanOrEqualTo(_bounds.height - 8));
      expect(placement.overlapsSelection, isTrue);
    });

    test('视口太小时压缩尺寸并保持落在边界内', () {
      const small = Size(200, 300);
      final placement = _place(
        const Rect.fromLTWH(10, 10, 40, 30),
        bounds: small,
      );
      expect(placement.shrunk, isTrue);
      expect(placement.rect.width, lessThanOrEqualTo(200 - 16));
      expect(placement.rect.height, lessThanOrEqualTo(300 - 16));
      expect(placement.rect.left, greaterThanOrEqualTo(8 - 1e-9));
      expect(placement.rect.top, greaterThanOrEqualTo(8 - 1e-9));
    });

    test('随机选区永远落在带边距的边界内', () {
      final random = math.Random(7);
      for (var i = 0; i < 40; i++) {
        final left = random.nextDouble() * (_bounds.width - 40);
        final top = random.nextDouble() * (_bounds.height - 40);
        final selection = Rect.fromLTWH(
          left,
          top,
          20 + random.nextDouble() * 100,
          20 + random.nextDouble() * 90,
        );
        final placement = _place(selection);
        final rect = placement.rect;
        expect(rect.left, greaterThanOrEqualTo(8 - 1e-9));
        expect(rect.top, greaterThanOrEqualTo(8 - 1e-9));
        expect(rect.right, lessThanOrEqualTo(_bounds.width - 8 + 1e-9));
        expect(rect.bottom, lessThanOrEqualTo(_bounds.height - 8 + 1e-9));
        // 放得下时不应压住选区。
        if (placement.side != MenuBarDialSide.clamped) {
          expect(rect.overlaps(selection), isFalse, reason: 'case $i');
        }
      }
    });
  });

  group('menuBarSelectionVisible', () {
    test('部分可见就继续显示', () {
      expect(
        menuBarSelectionVisible(const Rect.fromLTWH(10, -20, 50, 60), _bounds),
        isTrue,
      );
    });

    test('完全滚到上方或下方时隐藏', () {
      expect(
        menuBarSelectionVisible(const Rect.fromLTWH(10, -300, 50, 60), _bounds),
        isFalse,
      );
      expect(
        menuBarSelectionVisible(const Rect.fromLTWH(10, 600, 50, 60), _bounds),
        isFalse,
      );
    });

    test('横向也按同样规则判定', () {
      expect(
        menuBarSelectionVisible(
          const Rect.fromLTWH(400, 100, 50, 60),
          _bounds,
        ),
        isFalse,
      );
      expect(
        menuBarSelectionVisible(
          Rect.fromLTWH(10, 100, 50, 60).translate(0, 0),
          _bounds,
        ),
        isTrue,
      );
    });
  });
}
