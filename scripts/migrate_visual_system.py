#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 4 项「统一视觉系统」第三阶段迁移脚本。

把散落各页面的品牌绿/身份色/危险色字面量换成 app_semantic_colors.dart 的常量，
把纯颜色用途的 isDark 分支删掉，把圆角换成 app_tokens.dart 的令牌。
只改视觉，不改业务逻辑与数据结构。
"""
import os
import re

ROOT = os.path.dirname(os.path.abspath(__file__)) + "/.."
ROOT = os.path.normpath(ROOT)

# 不处理的文件：主题自身、桌面小组件（本轮范围外）
SKIP = {
    "lib/theme/app_theme.dart",
    "lib/theme/app_tokens.dart",
    "lib/theme/app_semantic_colors.dart",
    "lib/services/home_widget_service.dart",
}

# ---------------------------------------------------------------- 精确块替换
# 页面 AppBar / Scaffold 上为了配色而写的分支：底色与前景色交给主题。
BLOCKS = {
    "lib/screens/target_screen.dart": [
        ("""      backgroundColor: isDark ? colorScheme.surface : Colors.white,
      appBar: AppBar(
        title: const Text('我的计划', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        backgroundColor:
            isDark ? colorScheme.surface : const Color(0xFF96B462),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
""",
         """      appBar: AppBar(
        title: const Text('我的计划'),
        centerTitle: true,
"""),
        ("""              final cardColor = isDark
                  ? Color.lerp(
                      target.color,
                      colorScheme.surfaceContainerHigh,
                      0.45,
                    )!
                  : target.color;
""",
         """              final cardColor = context.adaptSemanticColor(target.color);
"""),
        ("""    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor =
        isDark ? Color.lerp(color, colorScheme.surfaceContainerHigh, 0.45)! : color;
""",
         """    final colorScheme = Theme.of(context).colorScheme;
    final cardColor = context.adaptSemanticColor(color);
"""),
        ("""          borderRadius: BorderRadius.circular(12.0),
          border: isDark
              ? Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.35))
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
""",
         """          borderRadius: AppRadius.cardAll,
          // 卡片：弱边框、少阴影
          border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
"""),
    ],
    "lib/screens/target_detail_screen.dart": [
        ("""      backgroundColor: isDark ? colorScheme.surface : Colors.white,
      appBar: AppBar(
        title: Text(target.name, style: TextStyle(color: isDark ? colorScheme.onSurface : Colors.white)),
        centerTitle: true,
        backgroundColor: isDark ? colorScheme.surface : const Color(0xFF96B462),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
""",
         """      appBar: AppBar(
        title: Text(target.name),
        centerTitle: true,
"""),
    ],
    "lib/screens/add_target_screen.dart": [
        ("""      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor:
            isDark ? colorScheme.surface : const Color(0xFF96B462),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leadingWidth: 80,
""",
         """      appBar: AppBar(
        leadingWidth: 80,
"""),
        ("""  Color _selectedColor = const Color(0xFFF16B77);
""",
         """  Color _selectedColor = AppSemanticColors.palette.first;
"""),
        ("""  final List<Color> _themeColors = [
    const Color(0xFFF16B77),
    const Color(0xFFF98E45),
    const Color(0xFFD9BD2E),
    const Color(0xFF96B462),
    const Color(0xFF4DA8EE),
    const Color(0xFF9575CD),
    const Color(0xFFE91E63),
  ];
""",
         """  final List<Color> _themeColors = AppSemanticColors.palette;
"""),
        ("""            color:
                isDark ? colorScheme.primaryContainer : const Color(0xFF96B462),
            borderRadius: BorderRadius.circular(6)),
        child: Text(
          text,
          style: TextStyle(
            color: isDark ? colorScheme.onPrimaryContainer : Colors.white,
          ),
        ),
""",
         """            color: colorScheme.primaryContainer,
            borderRadius: AppRadius.badgeAll),
        child: Text(
          text,
          style: TextStyle(color: colorScheme.onPrimaryContainer),
        ),
"""),
        ("""            foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
""", """            foregroundColor: colorScheme.onSurface,
"""),
        ("""                       color: isDark ? colorScheme.onSurface : Colors.white,
""", """                       color: colorScheme.onSurface,
"""),
        ("""                   color: isDark ? colorScheme.onSurface : Colors.white,
""", """                   color: colorScheme.onSurface,
"""),
        ("""    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Color.lerp(activeColor, colorScheme.surfaceContainerHigh, 0.45)!
        : activeColor;
""",
         """    final cardColor = context.adaptSemanticColor(activeColor);
"""),
    ],
    "lib/screens/add_check_in_goal_screen.dart": [
        ("""  static const _themeColors = [
    Color(0xFFF16B77),
    Color(0xFFF98E45),
    Color(0xFFD9BD2E),
    Color(0xFF96B462),
    Color(0xFF4DA8EE),
    Color(0xFF9575CD),
    Color(0xFFE91E63),
  ];
""",
         """  static const _themeColors = AppSemanticColors.palette;
"""),
    ],
    "lib/screens/event_detail_screen.dart": [
        ("""      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Text(eventName),
        elevation: 0,
        backgroundColor:
            isDark ? colorScheme.surfaceContainerHighest : Colors.white,
        foregroundColor: isDark ? colorScheme.onSurface : Colors.black,
      ),
""",
         """      appBar: AppBar(
        title: Text(eventName),
      ),
"""),
        ("""                                    : const Color(0xFFB5D390)
""", """                                    : AppSemanticColors.brandLight
"""),
    ],
    "lib/screens/global_search_screen.dart": [
        ("""      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF8F9FA),
      appBar: AppBar(
        backgroundColor: isDark ? colorScheme.primary : const Color(0xFF9CB86A),
        foregroundColor: isDark ? colorScheme.onPrimary : Colors.white,
        title: TextField(
""",
         """      appBar: AppBar(
        title: TextField(
"""),
        ("""          style: TextStyle(
            color: isDark ? colorScheme.onPrimary : Colors.white,
            fontSize: 16,
          ),
          decoration: InputDecoration(
            hintText: '搜索事件或分类…',
            hintStyle: TextStyle(
              color: (isDark ? colorScheme.onPrimary : Colors.white)
                  .withValues(alpha: 0.7),
            ),
""",
         """          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 16,
          ),
          decoration: InputDecoration(
            hintText: '搜索事件或分类…',
            hintStyle: TextStyle(
              color: colorScheme.onSurfaceVariant,
            ),
"""),
        ("""                      color: isDark
                          ? colorScheme.onPrimary.withValues(alpha: 0.7)
                          : Colors.white70,
""",
         """                      color: colorScheme.onSurfaceVariant,
"""),
    ],
    "lib/screens/diary_search_screen.dart": [
        ("""      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF8F9FA),
      appBar: AppBar(
        backgroundColor: isDark ? colorScheme.primary : const Color(0xFF9CB86A),
        foregroundColor: isDark ? colorScheme.onPrimary : Colors.white,
        title: TextField(
""",
         """      appBar: AppBar(
        title: TextField(
"""),
        ("""          style: TextStyle(
            color: isDark ? colorScheme.onPrimary : Colors.white,
            fontSize: 16,
          ),
          decoration: InputDecoration(
            hintText: '搜索日记内容…',
            hintStyle: TextStyle(
              color: (isDark ? colorScheme.onPrimary : Colors.white)
                  .withValues(alpha: 0.7),
            ),
""",
         """          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 16,
          ),
          decoration: InputDecoration(
            hintText: '搜索日记内容…',
            hintStyle: TextStyle(
              color: colorScheme.onSurfaceVariant,
            ),
"""),
        ("""                      color: isDark
                          ? colorScheme.onPrimary.withValues(alpha: 0.7)
                          : Colors.white70,
""",
         """                      color: colorScheme.onSurfaceVariant,
"""),
    ],
    "lib/screens/word_cloud_screen.dart": [
        ("""      final color = Color.lerp(
        const Color(0xFF6B8E3A),
        const Color(0xFF4A90E2),
        (i % 6) / 5,
      )!;
""",
         """      // 词云统一使用语义图表色板，不再各自写色
      final color = AppSemanticColors
          .wordCloud[i % AppSemanticColors.wordCloud.length];
"""),
    ],
    "lib/screens/check_in_map_screen.dart": [
        ("""        ? [
            const Color(0xFFFFD700),
            const Color(0xFFC0C0C0),
            const Color(0xFFCD7F32)
          ][rank - 1]
""",
         """        ? const [
            AppSemanticColors.medalGoldBright,
            AppSemanticColors.medalSilver,
            AppSemanticColors.medalBronze
          ][rank - 1]
"""),
    ],
    "lib/providers/time_provider.dart": [
        ("""  static const Color calendarImportColor = Color(0xFF78909C);
""", """  static const Color calendarImportColor = AppSemanticColors.calendarImport;
"""),
        ("""          color: const Color(0xFFD4AF37),
""", """          color: AppSemanticColors.medalGold,
"""),
        ("""          color: const Color(0xFF9CB86A),
          subCategories: ['会议', '文档'],
""", """          color: AppSemanticColors.brand,
          subCategories: ['会议', '文档'],
"""),
        ("""      Category(name: '运动', color: const Color(0xFF4A90E2), updatedAt: nowMs),
""",
         """      Category(name: '运动', color: AppSemanticColors.info, updatedAt: nowMs),
"""),
        ("""          color: const Color(0xFF9E9E9E),
""", """          color: AppSemanticColors.neutral,
"""),
    ],
    "lib/models/target.dart": [
        ("""      color: Color(json['color'] as int? ?? 0xFF9CB86A),
""",
         """      color: Color(json['color'] as int? ??
          AppSemanticColors.brand.toARGB32()),
"""),
    ],
    "lib/widgets/check_in_map_preview.dart": [
        ("""      return const Color(0xFF4DA8EE);
""", """      return AppSemanticColors.identityGuaiGuai;
"""),
        ("""      return const Color(0xFFF16B77);
""", """      return AppSemanticColors.identityJingJing;
"""),
        ("""    return const Color(0xFF96B462);
""", """    return AppSemanticColors.brandSurface;
"""),
    ],
}

# ---------------------------------------------------------------- 逐行替换
LINES = [
    # 纯颜色用途的 isDark 分支
    ("color: isDark ? colorScheme.outlineVariant : Colors.grey[300],",
     "color: colorScheme.outlineVariant,"),
    ("color: isDark ? colorScheme.onSurfaceVariant : Colors.grey[500],",
     "color: colorScheme.onSurfaceVariant,"),
    ("color: isDark ? colorScheme.onSurfaceVariant : Colors.grey[600],",
     "color: colorScheme.onSurfaceVariant,"),
    ("color: isDark ? colorScheme.onSurfaceVariant : Colors.grey[700],",
     "color: colorScheme.onSurfaceVariant,"),
    ("color: isDark ? colorScheme.onSurface : Colors.black87,",
     "color: colorScheme.onSurface,"),
    (": (isDark ? colorScheme.onSurface : Colors.black87),",
     ": colorScheme.onSurface,"),
    ("foregroundColor: isDark ? colorScheme.onSurface : Colors.white,",
     "foregroundColor: colorScheme.onSurface,"),
    ("backgroundColor: isDark ? colorScheme.surfaceContainerHighest : Colors.white,",
     "backgroundColor: AppSurfaces.of(context).card,"),
    ("isDark ? colorScheme.surfaceContainerHigh : Colors.white,",
     "AppSurfaces.of(context).card,"),
    ("""    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Color.lerp(target.color, colorScheme.surfaceContainerHigh, 0.45)!
        : target.color;""",
     """    final cardColor = context.adaptSemanticColor(target.color);"""),
    # 语义色字面量
    ("const Color(0xFF9CB86A)", "AppSemanticColors.brand"),
    ("Color(0xFF9CB86A)", "AppSemanticColors.brand"),
    ("const Color(0xFFB5D390)", "AppSemanticColors.brandLight"),
    ("Color(0xFFB5D390)", "AppSemanticColors.brandLight"),
    ("const Color(0xFF5A7A32)", "AppSemanticColors.brandDeep"),
    ("const Color(0xFF96B462)", "AppSemanticColors.brandSurface"),
    ("const Color(0xFF4DA8EE)", "AppSemanticColors.identityGuaiGuai"),
    ("Color(0xFF4DA8EE)", "AppSemanticColors.identityGuaiGuai"),
    ("const Color(0xFFF16B77)", "AppSemanticColors.identityJingJing"),
    ("Color(0xFFF16B77)", "AppSemanticColors.identityJingJing"),
    ("const Color(0xFFFE4A49)", "AppSemanticColors.danger"),
    ("const Color(0xFFF98E45)", "AppSemanticColors.warning"),
    ("const Color(0xFF4A90E2)", "AppSemanticColors.info"),
    ("const Color(0xFF78909C)", "AppSemanticColors.calendarImport"),
    ("const Color(0xFF9E9E9E)", "AppSemanticColors.neutral"),
    ("const Color(0xFFD4AF37)", "AppSemanticColors.medalGold"),
    ("const Color(0xFFFFD700)", "AppSemanticColors.medalGoldBright"),
    ("const Color(0xFFC0C0C0)", "AppSemanticColors.medalSilver"),
    ("const Color(0xFFCD7F32)", "AppSemanticColors.medalBronze"),
    ("const Color(0xFF9575CD)", "AppSemanticColors.lavender"),
    ("const Color(0xFFD9BD2E)", "AppSemanticColors.mustard"),
    ("const Color(0xFFE91E63)", "AppSemanticColors.rose"),
    ("Colors.orangeAccent", "AppSemanticColors.warning"),
    ("color = Colors.orange;", "color = AppSemanticColors.warning;"),
    ("? Colors.orange", "? AppSemanticColors.warning"),
    ("color = Colors.grey;", "color = AppSemanticColors.neutral;"),
]

# 圆角字面量 → 令牌（含 const 前缀一起替换，避免 `const AppRadius.x` 语法错误）
RADIUS = [
    (re.compile(r"const BorderRadius\.circular\((\d+(?:\.\d+)?)\)"),
     {4: "AppRadius.gridAll", 6: "AppRadius.badgeAll",
      10: "AppRadius.controlAll", 12: "AppRadius.controlAll",
      14: "AppRadius.cardAll", 16: "AppRadius.cardAll",
      20: "AppRadius.sheetAll", 24: "AppRadius.sheetAll"}),
    (re.compile(r"BorderRadius\.circular\((\d+(?:\.\d+)?)\)"),
     {4: "AppRadius.gridAll", 6: "AppRadius.badgeAll",
      10: "AppRadius.controlAll", 12: "AppRadius.controlAll",
      14: "AppRadius.cardAll", 16: "AppRadius.cardAll",
      20: "AppRadius.sheetAll", 24: "AppRadius.sheetAll"}),
    (re.compile(r"const Radius\.circular\((\d+(?:\.\d+)?)\)"),
     {4: "AppRadius.rGrid", 6: "AppRadius.rBadge",
      12: "AppRadius.rControl", 16: "AppRadius.rCard", 20: "AppRadius.rSheet"}),
    (re.compile(r"Radius\.circular\((\d+(?:\.\d+)?)\)"),
     {4: "AppRadius.rGrid", 6: "AppRadius.rBadge",
      12: "AppRadius.rControl", 16: "AppRadius.rCard", 20: "AppRadius.rSheet"}),
]

# 符号 → 需要补的 import
IMPORT_MAP = {
    "AppSemanticColors": "app_semantic_colors.dart",
    "AppTheme": "app_theme.dart",
    "AppSurfaces": "app_theme.dart",
    "adaptSemanticColor": "app_theme.dart",
    "AppRadius": "app_tokens.dart",
    "AppSpacing": "app_tokens.dart",
    "AppSizes": "app_tokens.dart",
    "AppText": "app_tokens.dart",
}


def dart_files():
    for base, _dirs, names in os.walk(os.path.join(ROOT, "lib")):
        for n in sorted(names):
            if not n.endswith(".dart"):
                continue
            full = os.path.join(base, n)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            if rel in SKIP:
                continue
            yield rel, full


def ensure_imports(rel, text):
    needed = set()
    for sym, mod in IMPORT_MAP.items():
        if re.search(r"\b%s\b" % sym, text):
            needed.add(mod)
    if not needed:
        return text, []
    added = []
    for mod in sorted(needed):
        imp = "../theme/%s" % mod
        if imp in text:
            continue
        # 插到最后一条 import 之后
        matches = list(re.finditer(r"^import\s+['\"].*?['\"];\s*$", text, re.M))
        if not matches:
            continue
        last = matches[-1]
        text = text[:last.end()] + "\nimport '" + imp + "';" + text[last.end():]
        added.append(imp)
    return text, added


def main():
    changed = []
    for rel, full in dart_files():
        src = open(full, encoding="utf-8").read()
        out = src
        for old, new in BLOCKS.get(rel, []):
            if old not in out:
                print("!! 块未命中 %s: %r" % (rel, old.split("\n")[0]))
            out = out.replace(old, new)
        for old, new in LINES:
            out = out.replace(old, new)
        for pattern, table in RADIUS:
            def repl(m, table=table):
                value = float(m.group(1))
                key = int(value) if value == int(value) else None
                if key is None or key not in table:
                    return m.group(0)
                return table[key]
            out = pattern.sub(repl, out)
        out, added = ensure_imports(rel, out)
        if out != src:
            open(full, "w", encoding="utf-8").write(out)
            changed.append((rel, added))
    print("改动文件 %d 个：" % len(changed))
    for rel, added in changed:
        print("  %-56s +%s" % (rel, ",".join(added) if added else "-"))


if __name__ == "__main__":
    main()
