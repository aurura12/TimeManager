#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 4 项「统一视觉系统」第三阶段迁移脚本（第二轮）。

处理第一轮剩下的 `isDark ? colorScheme.x : Colors.grey[n]` 这类"为选颜色而写的"
分支，以及卡片阴影/边框统一。只改视觉。
"""
import os
import re

ROOT = os.path.normpath(os.path.dirname(os.path.abspath(__file__)) + "/..")

DECL = "    final isDark = Theme.of(context).brightness == Brightness.dark;\n"

# 卡片阴影 → 弱边框 + 无阴影
CARD_BLOCK_OLD = """          decoration: BoxDecoration(
            color: isDark ? colorScheme.surfaceContainerHighest : Colors.white,
            borderRadius: AppRadius.cardAll,
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: isDark ? 0.02 : 0.03),
                blurRadius: 8,
              ),
            ],
          ),
"""
CARD_BLOCK_NEW = """          decoration: BoxDecoration(
            color: AppSurfaces.of(context).card,
            borderRadius: AppRadius.cardAll,
            // 卡片：弱边框、少阴影
            border: Border.all(color: AppSurfaces.of(context).border),
          ),
"""

CARD_BLOCK_OLD2 = """                decoration: BoxDecoration(
                  color: isDark
                      ? colorScheme.surfaceContainerHighest
                      : Colors.white,
                  borderRadius: AppRadius.cardAll,
                  boxShadow: [
                    BoxShadow(
                      color: (isDark ? Colors.white : Colors.black)
                          .withValues(alpha: isDark ? 0.02 : 0.03),
                      blurRadius: 8,
                    ),
                  ],
                ),
"""
CARD_BLOCK_NEW2 = """                decoration: BoxDecoration(
                  color: AppSurfaces.of(context).card,
                  borderRadius: AppRadius.cardAll,
                  // 卡片：弱边框、少阴影
                  border: Border.all(color: AppSurfaces.of(context).border),
                ),
"""

EXACT = {
    "lib/screens/global_search_screen.dart": [
        ("_rangeChip('全部', _SearchDateRange.all, isDark, colorScheme)",
         "_rangeChip('全部', _SearchDateRange.all, colorScheme)"),
        ("_rangeChip('近7天', _SearchDateRange.week, isDark, colorScheme)",
         "_rangeChip('近7天', _SearchDateRange.week, colorScheme)"),
        ("_rangeChip('近30天', _SearchDateRange.month, isDark, colorScheme)",
         "_rangeChip('近30天', _SearchDateRange.month, colorScheme)"),
        ("_rangeChip('近一年', _SearchDateRange.year, isDark, colorScheme)",
         "_rangeChip('近一年', _SearchDateRange.year, colorScheme)"),
        ("""    _SearchDateRange range,
    bool isDark,
    ColorScheme colorScheme,
""", """    _SearchDateRange range,
    ColorScheme colorScheme,
"""),
        ("""        selectedColor: isDark
            ? AppTheme.seedColor.withValues(alpha: 0.3)
            : AppSemanticColors.brand.withValues(alpha: 0.25),
        checkmarkColor:
            isDark ? AppSemanticColors.brandLight : AppSemanticColors.brand,
        labelStyle: TextStyle(
          color: selected ? AppSemanticColors.brandDeep : colorScheme.onSurface,
""",
         """        selectedColor: colorScheme.primaryContainer,
        checkmarkColor: colorScheme.onPrimaryContainer,
        labelStyle: TextStyle(
          color:
              selected ? colorScheme.onPrimaryContainer : colorScheme.onSurface,
"""),
        ("_buildSuggestions(suggestions, isDark, colorScheme)",
         "_buildSuggestions(suggestions, colorScheme)"),
        ("_buildEmpty(isDark, colorScheme)", "_buildEmpty(colorScheme)"),
        ("_buildResults(isDark, colorScheme)", "_buildResults(colorScheme)"),
        ("      List<String> labels, bool isDark, ColorScheme colorScheme) {",
         "      List<String> labels, ColorScheme colorScheme) {"),
        ("  Widget _buildEmpty(bool isDark, ColorScheme colorScheme) {",
         "  Widget _buildEmpty(ColorScheme colorScheme) {"),
        ("  Widget _buildResults(bool isDark, ColorScheme colorScheme) {",
         "  Widget _buildResults(ColorScheme colorScheme) {"),
    ],
    "lib/screens/diary_search_screen.dart": [
        ("_buildHint(isDark, colorScheme)", "_buildHint(colorScheme)"),
        ("_buildEmpty(isDark, colorScheme, query)", "_buildEmpty(colorScheme, query)"),
        ("_buildResults(isDark, colorScheme)", "_buildResults(colorScheme)"),
        ("  Widget _buildHint(bool isDark, ColorScheme colorScheme) {",
         "  Widget _buildHint(ColorScheme colorScheme) {"),
        ("  Widget _buildEmpty(bool isDark, ColorScheme colorScheme, String query) {",
         "  Widget _buildEmpty(ColorScheme colorScheme, String query) {"),
        ("  Widget _buildResults(bool isDark, ColorScheme colorScheme) {",
         "  Widget _buildResults(ColorScheme colorScheme) {"),
        (CARD_BLOCK_OLD2, CARD_BLOCK_NEW2),
    ],
    "lib/screens/global_search_screen.dart#2": [
        (CARD_BLOCK_OLD, CARD_BLOCK_NEW),
    ],
    "lib/screens/profile_screen.dart": [
        ("color: Colors.black.withValues(alpha: isDark ? 0.16 : 0.02),",
         "color: Colors.black.withValues(alpha: 0.04),"),
        ("color: Colors.black.withValues(alpha: isDark ? 0.16 : 0.05),",
         "color: Colors.black.withValues(alpha: 0.06),"),
    ],
}

# 逐条正则：把"为选颜色而写的"分支压成单一语义色
REGEX_RULES = [
    # isDark ? colorScheme.x : Colors.grey[...]  （允许跨行缩进）
    (re.compile(r"isDark\s*\?\s*colorScheme\.(\w+)\s*:\s*Colors\.grey(?:\[\d+\])?!?", re.S),
     r"colorScheme.\1"),
    # isDark ? colorScheme.x : Colors.black87 / Colors.grey
    (re.compile(r"isDark\s*\?\s*colorScheme\.(\w+)\s*:\s*Colors\.black87", re.S),
     r"colorScheme.\1"),
    (re.compile(r"isDark\s*\?\s*colorScheme\.(\w+)\s*:\s*Colors\.grey", re.S),
     r"colorScheme.\1"),
    # 深色下的品牌绿浅色变体：统一用 colorScheme.primary，两个主题都够对比
    (re.compile(r"isDark\s*\?\s*AppSemanticColors\.brandLight\s*:\s*"
                r"AppSemanticColors\.brand", re.S),
     r"colorScheme.primary"),
]


def main():
    changed = []
    for base, _dirs, names in os.walk(os.path.join(ROOT, "lib")):
        for n in sorted(names):
            if not n.endswith(".dart"):
                continue
            full = os.path.join(base, n)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            src = open(full, encoding="utf-8").read()
            out = src
            for key in (rel, rel + "#2"):
                for old, new in EXACT.get(key, []):
                    if old not in out:
                        print("!! 未命中 %s: %r" % (rel, old.split("\n")[0][:60]))
                    out = out.replace(old, new)
            for pattern, repl in REGEX_RULES:
                out = pattern.sub(repl, out)
            # 变量已无引用 → 删掉声明
            while out.count(DECL) > 0:
                probe = out.replace(DECL, "", 1)
                if "isDark" in probe:
                    break
                out = probe
            if out != src:
                open(full, "w", encoding="utf-8").write(out)
                changed.append(rel)
    print("第二轮改动 %d 个文件：%s" % (len(changed), ", ".join(changed)))


if __name__ == "__main__":
    main()
