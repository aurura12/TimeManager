/// 设计令牌 —— 只放"数值"。
///
/// 这里不定义任何颜色，颜色分两处：
/// - 主题色 / 表面层级：`app_theme.dart`
/// - 身份色、分类色、图表色等语义色：`app_semantic_colors.dart`
///
/// 规则见 `docs/design-system.md`。
library;

import 'package:flutter/material.dart';

/// 间距。手机版只用这一套：4 / 8 / 12 / 16 / 24。
abstract final class AppSpacing {
  /// 4 —— 徽标内边距、图标与文字之间
  static const double xs = 4;

  /// 8 —— 紧邻控件之间
  static const double sm = 8;

  /// 12 —— 模块之间（紧凑）
  static const double md = 12;

  /// 16 —— 页面左右边距、卡片内边距、模块之间
  static const double lg = 16;

  /// 24 —— 区块之间
  static const double xl = 24;

  /// 手机版页面左右边距
  static const double pageHorizontal = lg;

  /// 列表 / 网格行之间的分隔高度
  static const double rowGap = sm;

  static const EdgeInsets page =
      EdgeInsets.symmetric(horizontal: pageHorizontal);
  static const EdgeInsets card = EdgeInsets.all(md);
  static const EdgeInsets cardComfortable = EdgeInsets.all(lg);
  static const EdgeInsets chip = EdgeInsets.symmetric(horizontal: sm);
  static const EdgeInsets sheet = EdgeInsets.fromLTRB(lg, md, lg, lg);
}

/// 圆角。按用途分档，不做"一刀切"。
abstract final class AppRadius {
  /// 4 —— 时间块、网格、极小控件
  static const double grid = 4;

  /// 6 —— 徽标、模板 chip、子分类条
  static const double badge = 6;

  /// 12 —— 普通按钮、输入框、分段控件
  static const double control = 12;

  /// 16 —— 普通卡片、面板
  static const double card = 16;

  /// 20 —— 底部面板、弹窗
  static const double sheet = 20;

  /// 0 —— 连续时间块的连接处（必须为 0，否则出现缺口）
  static const double joined = 0;

  static const Radius rGrid = Radius.circular(grid);
  static const Radius rBadge = Radius.circular(badge);
  static const Radius rControl = Radius.circular(control);
  static const Radius rCard = Radius.circular(card);
  static const Radius rSheet = Radius.circular(sheet);
  static const Radius rJoined = Radius.circular(joined);

  static const BorderRadius gridAll = BorderRadius.all(rGrid);
  static const BorderRadius badgeAll = BorderRadius.all(rBadge);
  static const BorderRadius controlAll = BorderRadius.all(rControl);
  static const BorderRadius cardAll = BorderRadius.all(rCard);
  static const BorderRadius sheetAll = BorderRadius.all(rSheet);

  /// 底部面板 / 弹窗：只有上方两角
  static const BorderRadius sheetTop = BorderRadius.vertical(top: rSheet);

  /// 日期选择器面板：底部两角
  static const BorderRadius panelBottom = BorderRadius.vertical(bottom: rCard);
}

/// 控件尺寸。
abstract final class AppSizes {
  /// 可点击控件最小高度（无障碍触摸目标）
  static const double minTapTarget = 48;

  /// 普通按钮高度
  static const double button = 44;

  /// 输入框高度
  static const double input = 48;

  /// 小按钮 / 图标按钮的**视觉**尺寸。
  ///
  /// 触摸目标由 [minTapTarget] 保证，两者不要混用：视觉可以更紧凑，
  /// 但可点击区域不得小于 44。
  static const double iconButton = 40;

  /// 模板 / 分类 chip 高度
  static const double chip = 30;

  /// 分段控件高度
  static const double segmented = 36;

  /// 列表行高
  static const double listRow = 52;

  /// AppBar 高度
  static const double appBar = 56;

  /// 底部导航高度
  static const double navBar = 68;

  /// 时间网格行高（10 分钟格，保持不变）
  static const double gridRow = 45;

  /// 时间网格左侧时间轴宽度
  static const double gridTimeAxis = 55;

  /// 描边宽度
  static const double border = 1;

  /// 顶部边界（导航栏）的细线
  static const double hairline = 1;

  /// 弹窗最大宽度（手机版）
  static const double dialogMaxWidth = 400;
}

/// 文字层级。页面只引用语义层级，不自己写字号。
///
/// 这些 TextStyle 不带颜色，颜色由 Theme / colorScheme 决定；
/// 叠在实色块上的文字（如时间块标签）才显式给 [onColor]。
abstract final class AppText {
  /// 页面标题（AppBar / 大标题）
  static const TextStyle pageTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// 模块标题
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// 正文
  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.4,
  );

  /// 辅助信息
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.35,
  );

  /// 网格文字（10 分钟格 / 时间轴）
  static const TextStyle gridLabel = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    height: 1.1,
  );

  /// 标签 / 徽标文字
  static const TextStyle badge = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  /// 按钮文字
  static const TextStyle button = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
}
