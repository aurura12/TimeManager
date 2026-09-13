/// 语义色白名单 —— 身份色、分类色、图表色、奖牌色、状态色。
///
/// 这些颜色**不随浅色/深色主题切换**，也**不允许被品牌主色替换**，
/// 因为它们承载的是业务含义，而不是装饰。
///
/// 白名单来源见 `docs/design-system.md` 第二节。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

abstract final class AppSemanticColors {
  // ---------------------------------------------------------------------------
  // 品牌绿（种子色及其派生）。只在这里定义一次，其他文件禁止再写 0xFF9CB86A。
  // ---------------------------------------------------------------------------

  /// 品牌种子色，同时是"成功 / 同步完成"的语义色。
  static const Color brand = Color(0xFF9CB86A);

  /// 偏深的品牌绿，用于顶栏等需要更高对比的场景。
  static const Color brandSurface = Color(0xFF96B462);

  /// 品牌绿的浅色变体（选中态、强调）。
  static const Color brandLight = Color(0xFFB5D390);

  /// 品牌绿的深色变体（浅底上的绿色文字，保证对比度）。
  static const Color brandDeep = Color(0xFF5A7A32);

  /// 词云用的橄榄绿。
  static const Color olive = Color(0xFF6B8E3A);

  // ---------------------------------------------------------------------------
  // 身份色：乖乖 / 晶晶。日记、打卡、地图标记共用，任何页面不得自行改色。
  // ---------------------------------------------------------------------------

  static const Color identityGuaiGuai = Color(0xFF4DA8EE);
  static const Color identityJingJing = Color(0xFFF16B77);

  // ---------------------------------------------------------------------------
  // 奖牌色
  // ---------------------------------------------------------------------------

  static const Color medalGold = Color(0xFFD4AF37);
  static const Color medalGoldBright = Color(0xFFFFD700);
  static const Color medalSilver = Color(0xFFC0C0C0);
  static const Color medalBronze = Color(0xFFCD7F32);

  // ---------------------------------------------------------------------------
  // 状态色
  // ---------------------------------------------------------------------------

  /// 删除 / 错误
  static const Color danger = Color(0xFFFE4A49);

  /// 危险色的深色变体（浅底上的红色文字，保证对比度）。
  ///
  /// [danger] 在白底只有 3.34:1，当文字色不合格。这里是 `danger` 向黑推 30%，
  /// 白底 6.12:1、页面底 `#F8F9FA` 5.80:1 —— 与 [brandDeep] 同一套做法。
  ///
  /// 有 `BuildContext` 时优先用 `readableOn(danger, 实际底面)`（深色主题下
  /// 会正确保留亮红）；这个常量用于拿不到主题的兜底 UI（如启动失败页）。
  static const Color dangerDeep = Color(0xFFB23433);

  /// 警告 / 同步中
  static const Color warning = Color(0xFFF98E45);

  /// 成功 / 已完成
  static const Color success = brand;

  /// 信息 / 中性强调
  static const Color info = Color(0xFF4A90E2);

  /// 未分类
  static const Color neutral = Color(0xFF9E9E9E);

  /// Google 日历导入
  static const Color calendarImport = Color(0xFF78909C);

  // ---------------------------------------------------------------------------
  // 调色板成员（给下面两份调色板复用，单独命名便于页面直接引用）
  // ---------------------------------------------------------------------------

  /// 芥末黄
  static const Color mustard = Color(0xFFD9BD2E);

  /// 薰衣草紫
  static const Color lavender = Color(0xFF9575CD);

  /// 玫红
  static const Color rose = Color(0xFFE91E63);

  // ---------------------------------------------------------------------------
  // 调色板
  // ---------------------------------------------------------------------------

  /// 用户可选的分类 / 目标 / 打卡颜色。
  ///
  /// 与新增目标、新增打卡目标的取色器共用同一份，禁止各页面自己再抄一份。
  /// 顺序即取色器中的展示顺序（`add_check_in_goal_screen` 依赖下标取值）。
  static const List<Color> palette = <Color>[
    identityJingJing,
    warning,
    mustard,
    brandSurface,
    identityGuaiGuai,
    lavender,
    rose,
  ];

  /// 统计图表色板（趋势、分布、图例）。
  static const List<Color> chart = <Color>[
    brand,
    warning,
    lavender,
    info,
    identityGuaiGuai,
    identityJingJing,
  ];

  /// 词云色板。
  static const List<Color> wordCloud = <Color>[
    olive,
    brand,
    info,
    warning,
    lavender,
  ];

  /// 「分类自定义颜色」取色器的色相基准（8 色相 × 明度矩阵，见首页 `_buildColorPalette`）。
  ///
  /// 这是用户可自由取色的色域，属于白名单；集中在这里只是为了不再于页面内联写色。
  static const List<Color> pickerHues = <Color>[
    Color(0xFFF44336), // 红
    Color(0xFFFF9800), // 橙
    Color(0xFFFFEB3B), // 黄
    Color(0xFF4CAF50), // 绿
    Color(0xFF00BCD4), // 青
    Color(0xFF2196F3), // 蓝
    Color(0xFF9C27B0), // 紫
    Color(0xFFE91E63), // 粉
  ];

  // ---------------------------------------------------------------------------
  // 实色块上的文字色
  // ---------------------------------------------------------------------------

  /// WCAG 相对对比度。测试与下面的可读色推导都用它。
  static double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = math.max(la, lb);
    final lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 把带透明度的 [color] 压到 [surface] 上，得到"实际看到"的那个颜色。
  ///
  /// `computeLuminance()` 会忽略 alpha，所以半透明色**必须先合成再比对比度**，
  /// 否则算的是没叠上去的那个色，结论会反。
  static Color compose(Color color, Color surface) =>
      color.a >= 1.0 ? color : Color.alphaBlend(color, surface);

  /// 把用户取到的颜色强制变成不透明。
  ///
  /// 分类 / 目标 / 打卡颜色都只该是不透明实色：用户可以在十六进制输入框里写 8 位
  /// ARGB（例如 `80FFFFFF`），一旦存进 `Category.color` 再流到时间块，那块底色就是
  /// 半透明的 —— 文字色要靠合成后的底色才能算对，而合成色又取决于它压在什么上面。
  /// 所以**在所有入口把 alpha 收成 FF**，而不是让渲染层去猜底面。
  static Color opaque(Color color) =>
      color.a >= 1.0 ? color : color.withValues(alpha: 1.0);

  /// 解析分类取色器中的十六进制输入，并强制丢弃 alpha。
  ///
  /// 接受 `RRGGBB`、`AARRGGBB` 以及带 `#` / `0x` 前缀的写法。8 位输入按
  /// ARGB 处理，但分类色最终始终返回不透明的 `Color`。
  static Color? parseOpaqueHex(String value) {
    var clean = value.trim().replaceAll('#', '').toUpperCase();
    if (clean.startsWith('0X')) clean = clean.substring(2);
    if (clean.length != 6 && clean.length != 8) return null;

    final rgb = clean.length == 8 ? clean.substring(2) : clean;
    final parsed = int.tryParse(rgb, radix: 16);
    return parsed == null ? null : Color(0xFF000000 | parsed);
  }

  /// 语义色当背景用的淡色调：把 [color] 以 [alpha] 压到 [surface] 上并**返回不透明结果**。
  ///
  /// 返回值可以直接拿去算对比度，也可以直接当 `BoxDecoration.color`（视觉与半透明等价，
  /// 因为底下就是 [surface]）。
  static Color tint(Color color, Color surface, [double alpha = 0.15]) =>
      Color.alphaBlend(color.withValues(alpha: alpha), surface);

  /// 语义色**当文字/图标用**时的可读版本。
  ///
  /// 语义色直接当文字色在浅底上常常读不清（品牌绿在白底只有 2.2:1）。
  /// 这里保持色相，朝"远离底面"的方向逐步推，直到对比度 ≥ [minRatio]（默认 4.5）。
  ///
  /// [color] 是半透明时会先与 [surface] 合成再比 —— 返回值也一定不透明，
  /// 否则把它当文字色用会再次踩到 alpha 的坑。
  static Color readableOn(Color color, Color surface, {double minRatio = 4.5}) {
    final base = compose(color, surface);
    if (contrastRatio(base, surface) >= minRatio) return base;
    final target = surface.computeLuminance() > 0.5
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
    for (var step = 1; step <= 10; step++) {
      final candidate = Color.lerp(base, target, step / 10)!;
      if (contrastRatio(candidate, surface) >= minRatio) return candidate;
    }
    return target;
  }

  /// 叠在「[color] 自己的淡色调」上的文字/图标色。
  ///
  /// 典型场景：状态徽标、奖牌圆点、统计卡 —— 底是同色 12%~15% 淡色调，
  /// 文字如果还用它本身的色相就会糊在一起。
  static Color onTint(
    Color color,
    Color surface, {
    double alpha = 0.15,
    double minRatio = 4.5,
  }) =>
      readableOn(color, tint(color, surface, alpha), minRatio: minRatio);

  /// 叠在语义实色上的文字/图标该用黑还是白。
  ///
  /// 用户可选色里有浅色（芥末黄 `#D9BD2E` 与白色仅 1.86:1、`brandSurface`
  /// `#96B462` 仅 2.33:1），固定白字会掉到不可读。这里按背景亮度在
  /// 「白字」与「黑字」之间取对比度更高的一方。
  ///
  /// [background] 是半透明时**必须**传 [over]，否则会比错色 —— 见 [compose]。
  static Color onColor(Color background, {Color? over}) {
    assert(
      background.a >= 1.0 || over != null,
      'onColor 收到半透明背景却没传 over：对比度会按未合成的颜色算，结论可能反。'
      '请传 over: AppSurfaces.of(context).page / .card 等实际底面，'
      '或改用 AppSemanticColors.tint() / onTint()。',
    );
    final effective = compose(background, over ?? const Color(0xFFFFFFFF));
    final luminance = effective.computeLuminance();
    // 纯白/纯黑对比度：白字 = 1.05 / (L + 0.05)，黑字 = (L + 0.05) / 0.05
    final onWhite = 1.05 / (luminance + 0.05);
    final onBlack = (luminance + 0.05) / 0.05;
    return onWhite >= onBlack
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF000000);
  }

  /// [onColor] 的次级版本（描边、次要文字）。
  static Color onColorMuted(Color background,
          [double alpha = 0.7, Color? over]) =>
      onColor(background, over: over).withValues(alpha: alpha);

  /// 按索引循环取用 [palette]。
  static Color paletteAt(int index) => palette[index % palette.length];

  /// 按索引循环取用 [chart]。
  static Color chartAt(int index) => chart[index % chart.length];
}
