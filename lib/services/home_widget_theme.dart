import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';

/// Android 桌面小组件的一套配色。
///
/// 只由 [ColorScheme] / [AppSurfaces] / [AppSemanticColors] 派生，
/// 不在这里写任何颜色字面量——小组件要跟着 App 外观走，不能另起一套常量。
/// 卡片底色与描边不在这里：RemoteViews 没法在运行期拼「圆角 + 描边」的
/// drawable，它们由 Android 侧的两份 shape 资源决定。
@immutable
class HomeWidgetPalette {
  const HomeWidgetPalette({
    required this.title,
    required this.stats,
    required this.body,
    required this.secondary,
    required this.axis,
    required this.chipBackground,
    required this.chipText,
    required this.actionBackground,
    required this.actionPressed,
    required this.actionText,
    required this.track,
    required this.nowLine,
    required this.statusSuccess,
    required this.statusError,
  });

  /// 日期标题
  final Color title;

  /// 统计行（品牌绿语义色，不随主题色变）
  final Color stats;

  ///「当前：…」
  final Color body;

  ///「接下来：…」与分类摘要
  final Color secondary;

  /// 时间轴 7 / 12 / 18 / 24 刻度
  final Color axis;

  /// 待同步徽章底 / 字
  final Color chipBackground;
  final Color chipText;

  /// 快捷入口底 / 按下底 / 字（跟随主题色）
  final Color actionBackground;
  final Color actionPressed;
  final Color actionText;

  /// 时间轴空轨与「现在」竖线
  final Color track;
  final Color nowLine;

  /// 动作反馈的成功 / 失败文字色
  final Color statusSuccess;
  final Color statusError;

  /// 原生侧按这些键读取（见 `WidgetTheme.parse`），改名要同步改 Kotlin。
  Map<String, Object?> toJson() => <String, Object?>{
        'title': title.toARGB32(),
        'stats': stats.toARGB32(),
        'body': body.toARGB32(),
        'secondary': secondary.toARGB32(),
        'axis': axis.toARGB32(),
        'chipBg': chipBackground.toARGB32(),
        'chipText': chipText.toARGB32(),
        'actionBg': actionBackground.toARGB32(),
        'actionPressed': actionPressed.toARGB32(),
        'actionText': actionText.toARGB32(),
        'track': track.toARGB32(),
        'nowLine': nowLine.toARGB32(),
        'statusOk': statusSuccess.toARGB32(),
        'statusError': statusError.toARGB32(),
      };
}

/// 小组件外观的推导与序列化。
abstract final class HomeWidgetTheme {
  /// 原生侧只认这个版本号；加字段时同步改 `WidgetTheme.parse`。
  static const int schemaVersion = 1;

  /// 一次编码会同时要浅色与深色两套，命中率很低，只留最近几组避免无限增长。
  static const int _cacheCapacity = 8;
  static final Map<String, HomeWidgetPalette> _cache =
      <String, HomeWidgetPalette>{};

  /// 由主题色 + 亮度推导小组件配色。
  ///
  /// 刻意不用 `Theme.of(context).colorScheme`：启用壁纸时卡面会带透明度，
  /// 而且 `AnimatedTheme` 切换过程中颜色是逐帧插值的。
  static HomeWidgetPalette paletteFor({
    required Color seedColor,
    required Brightness brightness,
  }) {
    final key = '${seedColor.toARGB32()}|${brightness.name}';
    final cached = _cache[key];
    if (cached != null) return cached;

    final scheme =
        AppTheme.themeFor(brightness, seedColor: seedColor).colorScheme;
    final surfaces = AppSurfaces.forColorScheme(scheme);
    final palette = HomeWidgetPalette(
      title: scheme.onSurface,
      // 品牌绿是语义色（成功 / 同步完成），design-system 规定不随主题色变。
      stats: AppSemanticColors.brand,
      body: scheme.onSurface,
      secondary: scheme.onSurfaceVariant,
      axis: AppSemanticColors.compose(
        scheme.onSurfaceVariant.withValues(alpha: 0.75),
        surfaces.card,
      ),
      chipBackground: AppSemanticColors.tint(
          AppSemanticColors.warning, surfaces.card, 0.18),
      chipText: AppSemanticColors.onTint(
        AppSemanticColors.warning,
        surfaces.card,
        alpha: 0.18,
      ),
      actionBackground: scheme.primaryContainer,
      actionPressed: Color.alphaBlend(
        scheme.onPrimaryContainer.withValues(alpha: 0.12),
        scheme.primaryContainer,
      ),
      actionText: scheme.onPrimaryContainer,
      track: surfaces.gridEmpty,
      // 与 App 内 CurrentTimeMarker 的 error 色对齐。
      nowLine: scheme.error,
      statusSuccess: AppSemanticColors.readableOn(
          AppSemanticColors.success, surfaces.card),
      statusError:
          AppSemanticColors.readableOn(AppSemanticColors.danger, surfaces.card),
    );

    if (_cache.length >= _cacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = palette;
    return palette;
  }

  /// 生成写入 `widget_theme` 的 JSON。
  ///
  /// 两套配色一起下发：App 进程不在时，原生侧仍能按系统夜色重新渲染
  /// （`updatePeriodMillis`、改尺寸、开机都走 `onUpdate`）。
  static String encode({
    required Color seedColor,
    required Brightness resolvedBrightness,
    required bool followsSystem,
  }) {
    return jsonEncode(<String, Object?>{
      'v': schemaVersion,
      'sys': followsSystem,
      'mode': resolvedBrightness.name,
      'light': paletteFor(seedColor: seedColor, brightness: Brightness.light)
          .toJson(),
      'dark': paletteFor(seedColor: seedColor, brightness: Brightness.dark)
          .toJson(),
    });
  }
}
