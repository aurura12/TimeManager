import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:time_manager/services/home_widget_theme.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';
import 'package:time_manager/theme/app_theme.dart';

void main() {
  const paletteKeys = <String>{
    'title',
    'stats',
    'body',
    'secondary',
    'axis',
    'chipBg',
    'chipText',
    'actionBg',
    'actionPressed',
    'actionText',
    'track',
    'nowLine',
    'statusOk',
    'statusError',
  };

  group('HomeWidgetTheme.paletteFor', () {
    test('浅色与深色的关键角色不同', () {
      final light = HomeWidgetTheme.paletteFor(
        seedColor: AppTheme.seedColor,
        brightness: Brightness.light,
      );
      final dark = HomeWidgetTheme.paletteFor(
        seedColor: AppTheme.seedColor,
        brightness: Brightness.dark,
      );

      expect(light.title, isNot(dark.title));
      expect(light.body, isNot(dark.body));
      expect(light.secondary, isNot(dark.secondary));
      expect(light.track, isNot(dark.track));
      expect(light.actionBackground, isNot(dark.actionBackground));
      // 品牌绿是语义色，浅深都不变。
      expect(light.stats, dark.stats);
    });

    test('所有颜色都不透明', () {
      for (final brightness in Brightness.values) {
        final palette = HomeWidgetTheme.paletteFor(
          seedColor: AppTheme.seedColor,
          brightness: brightness,
        );
        final colors = <Color>[
          palette.title,
          palette.stats,
          palette.body,
          palette.secondary,
          palette.axis,
          palette.chipBackground,
          palette.chipText,
          palette.actionBackground,
          palette.actionPressed,
          palette.actionText,
          palette.track,
          palette.nowLine,
          palette.statusSuccess,
          palette.statusError,
        ];
        for (final color in colors) {
          expect(color.a, 1.0, reason: '${brightness.name} 下出现半透明色 $color');
        }
      }
    });

    test('自定义主题色只影响按钮，不影响语义色', () {
      final blue = HomeWidgetTheme.paletteFor(
        seedColor: AppThemeColorPreset.blue.color,
        brightness: Brightness.light,
      );
      final rose = HomeWidgetTheme.paletteFor(
        seedColor: AppThemeColorPreset.rose.color,
        brightness: Brightness.light,
      );

      expect(blue.actionBackground, isNot(rose.actionBackground));
      expect(blue.actionPressed, isNot(rose.actionPressed));
      expect(blue.actionText, isNot(rose.actionText));
      // 品牌绿与警告色属于语义色，不随主题色变。
      expect(blue.stats, rose.stats);
      expect(blue.chipBackground, rose.chipBackground);
      expect(blue.chipText, rose.chipText);
    });
  });

  group('HomeWidgetTheme.encode', () {
    test('结构与 Kotlin 侧 `WidgetTheme.parse` 的约定一致', () {
      final raw = HomeWidgetTheme.encode(
        seedColor: AppTheme.seedColor,
        resolvedBrightness: Brightness.light,
        followsSystem: false,
      );
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(decoded.keys.toSet(), {'v', 'sys', 'mode', 'light', 'dark'});
      expect(decoded['v'], HomeWidgetTheme.schemaVersion);
      expect(decoded['sys'], isFalse);
      expect(decoded['mode'], 'light');
      for (final section in ['light', 'dark']) {
        expect(
          (decoded[section] as Map).keys.toSet(),
          paletteKeys,
          reason: '$section 的键集合必须与 WidgetTheme.kt 一一对应',
        );
      }
      expect(jsonDecode(jsonEncode(decoded)), decoded);
    });

    test('followsSystem 只翻转 sys，不改两套配色', () {
      final fixed = jsonDecode(HomeWidgetTheme.encode(
        seedColor: AppThemeColorPreset.purple.color,
        resolvedBrightness: Brightness.dark,
        followsSystem: false,
      )) as Map<String, dynamic>;
      final system = jsonDecode(HomeWidgetTheme.encode(
        seedColor: AppThemeColorPreset.purple.color,
        resolvedBrightness: Brightness.dark,
        followsSystem: true,
      )) as Map<String, dynamic>;

      expect(system['sys'], isTrue);
      expect(system['mode'], 'dark');
      expect(system['light'], fixed['light']);
      expect(system['dark'], fixed['dark']);
    });
  });

  group('小组件配色可读性', () {
    test('8 个预设主题色 × 浅深两色都满足对比度要求', () {
      for (final preset in AppThemeColorPreset.values) {
        for (final brightness in Brightness.values) {
          final scheme = AppTheme.themeFor(brightness, seedColor: preset.color)
              .colorScheme;
          final card = AppSurfaces.forColorScheme(scheme).card;
          final palette = HomeWidgetTheme.paletteFor(
            seedColor: preset.color,
            brightness: brightness,
          );
          final reason = '${preset.label} / ${brightness.name}';

          expect(
            AppSemanticColors.contrastRatio(palette.body, card),
            greaterThanOrEqualTo(4.5),
            reason: '$reason 正文不可读',
          );
          expect(
            AppSemanticColors.contrastRatio(palette.secondary, card),
            greaterThanOrEqualTo(4.5),
            reason: '$reason 次要文字不可读',
          );
          expect(
            AppSemanticColors.contrastRatio(palette.axis, card),
            greaterThanOrEqualTo(3.5),
            reason: '$reason 刻度不可读',
          );
          expect(
            AppSemanticColors.contrastRatio(
              palette.chipText,
              palette.chipBackground,
            ),
            greaterThanOrEqualTo(4.5),
            reason: '$reason 待同步徽章不可读',
          );
          expect(
            AppSemanticColors.contrastRatio(
              palette.actionText,
              palette.actionBackground,
            ),
            greaterThanOrEqualTo(4.5),
            reason: '$reason 快捷入口不可读',
          );
          expect(
            AppSemanticColors.contrastRatio(
              palette.actionText,
              palette.actionPressed,
            ),
            greaterThanOrEqualTo(4.5),
            reason: '$reason 快捷入口按下态不可读',
          );
        }
      }
    });
  });
}
