#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重放流水线的补充规则（收尾阶段）。

前两轮脚本是在"已经过手工编辑的中间态"上写的，个别块依赖中间态文本；
这里把那些依赖中间态的改动改写成在 HEAD 原文上也能命中的形式。
"""
import re

# 全局：整段卡片装饰（含不同缩进）
CARD_BLOCK = re.compile(
    r"(?P<i>[ ]*)color: isDark\s*\?\s*colorScheme\.surfaceContainerHighest"
    r"\s*:\s*Colors\.white,\s*"
    r"borderRadius: AppRadius\.cardAll,\s*"
    r"boxShadow: \[\s*BoxShadow\(\s*"
    r"color: \(isDark \? Colors\.white : Colors\.black\)\s*"
    r"\.withValues\(alpha: isDark \? 0\.02 : 0\.03\),\s*"
    r"blurRadius: 8,\s*\),\s*\],",
    re.S,
)


def _card_block(m):
    i = m.group("i")
    return (
        f"{i}color: AppSurfaces.of(context).card,\n"
        f"{i}borderRadius: AppRadius.cardAll,\n"
        f"{i}// 卡片：弱边框、少阴影\n"
        f"{i}border: Border.all(color: AppSurfaces.of(context).border),"
    )


GLOBAL_REGEX = [
    (CARD_BLOCK, _card_block),
    # 纯为配色而写的分支
    (re.compile(r"color: isDark \? colorScheme\.onSurface : Colors\.white,"),
     "color: colorScheme.onSurface,"),
]

GLOBAL_LINES = []

BY_FILE = {
    "lib/screens/diary_search_screen.dart": [
        # 这个文件新增了 AppSurfaces 依赖，导入按字母序补到中间
        ("import '../theme/app_semantic_colors.dart';\n"
         "import '../theme/app_tokens.dart';",
         "import '../theme/app_semantic_colors.dart';\n"
         "import '../theme/app_theme.dart';\n"
         "import '../theme/app_tokens.dart';"),
    ],
    "lib/screens/add_target_screen.dart": [
        ("    final colorScheme = Theme.of(context).colorScheme;\n"
         "    final isDark = Theme.of(context).brightness == Brightness.dark;\n"
         "    Color activeColor = _selectedColor;",
         "    final colorScheme = Theme.of(context).colorScheme;\n"
         "    Color activeColor = _selectedColor;"),
        ("    final colorScheme = Theme.of(context).colorScheme;\n"
         "    final cardColor = context.adaptSemanticColor(activeColor);",
         "    final cardColor = context.adaptSemanticColor(activeColor);"),
        ("    final colorScheme = Theme.of(context).colorScheme;\n"
         "    final isDark = Theme.of(context).brightness == Brightness.dark;\n"
         "    return GestureDetector(",
         "    final colorScheme = Theme.of(context).colorScheme;\n"
         "    return GestureDetector("),
    ],
    "lib/screens/profile_screen.dart": [
        ("    final colorScheme = Theme.of(context).colorScheme;\n"
         "    final isDark = Theme.of(context).brightness == Brightness.dark;\n"
         "    return Container(\n      height: 220,",
         "    final colorScheme = Theme.of(context).colorScheme;\n"
         "    return Container(\n      height: 220,"),
        ("    final colorScheme = Theme.of(context).colorScheme;\n"
         "    final isDark = Theme.of(context).brightness == Brightness.dark;\n"
         "    return Container(\n      height: 45,",
         "    final colorScheme = Theme.of(context).colorScheme;\n"
         "    return Container(\n      height: 45,"),
        ("borderRadius: BorderRadius.circular(25),",
         "borderRadius: AppRadius.sheetAll,"),
        ("borderRadius: BorderRadius.circular(15),",
         "borderRadius: AppRadius.cardAll,"),
    ],
    "lib/screens/global_search_screen.dart": [
        ("""        selectedColor: isDark
            ? AppTheme.seedColor.withValues(alpha: 0.3)
            : AppSemanticColors.brand.withValues(alpha: 0.25),
        checkmarkColor: isDark
            ? AppSemanticColors.brandLight
            : AppSemanticColors.brand,
        labelStyle: TextStyle(
          color: selected
              ? AppSemanticColors.brandDeep
              : colorScheme.onSurface,
""",
         """        selectedColor: colorScheme.primaryContainer,
        checkmarkColor: colorScheme.onPrimaryContainer,
        labelStyle: TextStyle(
          color:
              selected ? colorScheme.onPrimaryContainer : colorScheme.onSurface,
"""),
        ("_rangeChip('全部', _SearchDateRange.all, isDark, colorScheme)",
         "_rangeChip('全部', _SearchDateRange.all, colorScheme)"),
        ("_rangeChip('近7天', _SearchDateRange.week, isDark, colorScheme)",
         "_rangeChip('近7天', _SearchDateRange.week, colorScheme)"),
        ("_rangeChip('近30天', _SearchDateRange.month, isDark, colorScheme)",
         "_rangeChip('近30天', _SearchDateRange.month, colorScheme)"),
        ("_rangeChip('近一年', _SearchDateRange.year, isDark, colorScheme)",
         "_rangeChip('近一年', _SearchDateRange.year, colorScheme)"),
        ("    _SearchDateRange range,\n    bool isDark,\n    ColorScheme colorScheme,\n",
         "    _SearchDateRange range,\n    ColorScheme colorScheme,\n"),
        ("_buildSuggestions(suggestions, isDark, colorScheme)",
         "_buildSuggestions(suggestions, colorScheme)"),
        ("_buildEmpty(isDark, colorScheme)", "_buildEmpty(colorScheme)"),
        ("_buildResults(isDark, colorScheme)", "_buildResults(colorScheme)"),
        ("      List<String> labels, bool isDark, ColorScheme colorScheme) {",
         "      List<String> labels, ColorScheme colorScheme) {"),
        ("  Widget _buildSuggestions(List<String> labels, bool isDark, ColorScheme colorScheme) {",
         "  Widget _buildSuggestions(List<String> labels, ColorScheme colorScheme) {"),
        ("  Widget _buildEmpty(bool isDark, ColorScheme colorScheme) {",
         "  Widget _buildEmpty(ColorScheme colorScheme) {"),
        ("  Widget _buildResults(bool isDark, ColorScheme colorScheme) {",
         "  Widget _buildResults(ColorScheme colorScheme) {"),
    ],
}

REGEX_BY_FILE = {
    "lib/screens/global_search_screen.dart": [
        # 日期范围 chip：选中态统一走 primaryContainer（HEAD 里是两套绿 + 括号写法）
        (re.compile(
            r"selectedColor: isDark\s*\?\s*AppTheme\.seedColor\.withValues\(alpha: 0\.3\)"
            r"\s*:\s*AppSemanticColors\.brand\.withValues\(alpha: 0\.25\),"),
         "selectedColor: colorScheme.primaryContainer,"),
        # checkmarkColor：pass2 的正则会先把 brandLight/brand 压成 colorScheme.primary
        (re.compile(
            r"checkmarkColor:\s*isDark\s*\?\s*AppSemanticColors\.brandLight\s*:\s*"
            r"AppSemanticColors\.brand,"),
         "checkmarkColor: colorScheme.onPrimaryContainer,"),
        (re.compile(r"checkmarkColor: colorScheme\.primary,"),
         "checkmarkColor: colorScheme.onPrimaryContainer,"),
        (re.compile(
            r"color: selected\s*\?\s*AppSemanticColors\.brandDeep\s*:\s*"
            r"\(?\s*colorScheme\.onSurface\s*\)?,"),
         "color:\n"
         "          selected ? colorScheme.onPrimaryContainer : colorScheme.onSurface,"),
    ],
    "lib/screens/event_detail_screen.dart": [
        (re.compile(r"style: TextStyle\(\s*fontSize: 16,\s*"
                    r"fontWeight: FontWeight\.bold,\s*"
                    r"color: colorScheme\.primary\)\),"),
         "style: const TextStyle(\n"
         "                                fontSize: 16,\n"
         "                                fontWeight: FontWeight.bold,\n"
         "                                color: AppSemanticColors.brand)),"),
    ],
}


def apply(rel, text):
    for old, new in GLOBAL_LINES:
        text = text.replace(old, new)
    for pattern, repl in GLOBAL_REGEX:
        text = pattern.sub(repl, text)
    for old, new in BY_FILE.get(rel, []):
        text = text.replace(old, new)
    for pattern, repl in REGEX_BY_FILE.get(rel, []):
        text = pattern.sub(repl, text)
    return text
