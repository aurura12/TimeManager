import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/color_picker_panel.dart';

void main() {
  Future<ValueNotifier<Color>> openPicker(
    WidgetTester tester, {
    Color initial = const Color(0xFF00FF00),
    bool enabled = true,
  }) async {
    final selection = ValueNotifier(initial);
    addTearDown(selection.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: ValueListenableBuilder<Color>(
              valueListenable: selection,
              builder: (context, color, _) => ColorPickerPanel(
                color: color,
                onChanged: enabled ? (color) => selection.value = color : null,
              ),
            ),
          ),
        ),
      ),
    ));
    return selection;
  }

  testWidgets('面板点选明暗和饱和度，拖动超出边界仍得到合法不透明颜色', (tester) async {
    final selection = await openPicker(tester);
    final rect =
        tester.getRect(find.byKey(const ValueKey('color-picker-plane')));
    await tester.tapAt(rect.center);
    await tester.pump();
    final middle = HSVColor.fromColor(selection.value);
    expect(middle.saturation, closeTo(0.5, 0.01));
    expect(middle.value, closeTo(0.5, 0.01));

    final drag = await tester.startGesture(
      rect.center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(rect.bottomRight + const Offset(30, 30));
    await tester.pump();
    expect(selection.value, Colors.black);
    await drag.moveTo(rect.topRight + const Offset(30, -30));
    await drag.up();
    await tester.pump();
    expect(selection.value, const Color(0xFF00FF00));
    expect(selection.value.a, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('灰阶颜色也能先选色相，再从面板得到该色相', (tester) async {
    for (final initial in [
      Colors.white,
      Colors.black,
      const Color(0xFF808080)
    ]) {
      final selection = await openPicker(tester, initial: initial);
      final slider = find.byType(Slider);
      await tester.tapAt(tester.getRect(slider).center);
      await tester.pump();
      final selectedHue = tester.widget<Slider>(slider).value;
      expect(selectedHue, closeTo(180, 1));

      final rect =
          tester.getRect(find.byKey(const ValueKey('color-picker-plane')));
      await tester
          .tapAt(rect.topLeft + Offset(rect.width * 0.8, rect.height * 0.2));
      await tester.pump();
      final selected = HSVColor.fromColor(selection.value);
      expect(selected.hue, closeTo(selectedHue, 1));
      expect(selected.saturation, closeTo(0.8, 0.01));
      expect(selected.value, closeTo(0.8, 0.01));
      expect(selection.value.a, 1);
      await tester.pumpWidget(const SizedBox());
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面方向键可以分别微调饱和度和明暗', (tester) async {
    final selection = await openPicker(tester);
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('color-picker-plane'))).center,
    );
    await tester.pump();
    final original = HSVColor.fromColor(selection.value);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final brighter = HSVColor.fromColor(selection.value);
    expect(brighter.value, greaterThan(original.value));
    expect(brighter.saturation, closeTo(original.saturation, 0.01));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final moreSaturated = HSVColor.fromColor(selection.value);
    expect(moreSaturated.saturation, greaterThan(brighter.saturation));
    expect(moreSaturated.value, closeTo(brighter.value, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存期间禁用取色控件，点选不会修改颜色', (tester) async {
    final selection = await openPicker(tester, enabled: false);
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('color-picker-plane'))).center,
    );
    await tester.pump();
    expect(selection.value, const Color(0xFF00FF00));
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(tester.takeException(), isNull);
  });
}
