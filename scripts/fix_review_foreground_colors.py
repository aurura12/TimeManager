#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二轮评审修复：把所有"前景色写死"的地方收敛到 onColor / onPrimary。

覆盖：
- estimateBrightnessForColor 手写三元 → AppSemanticColors.onColor
- 语义实色上的写死白字（danger / warning / success / 图表色 / 分类色）
- colorScheme.primary 背景上的白字 → colorScheme.onPrimary
- Colors.grey / grey[600] / redAccent 等"无主题感知"的颜色 → 主题令牌或语义色
"""
import os
import re

ROOT = os.path.normpath(os.path.dirname(os.path.abspath(__file__)) + "/..")

IMPORTS = {}

# 全局：手写的 estimateBrightnessForColor 三元
GLOBAL_REGEX = [
    # xxx = ThemeData.estimateBrightnessForColor(c) == Brightness.dark ? Colors.white : Colors.black87/black;
    (re.compile(
        r"ThemeData\.estimateBrightnessForColor\(([A-Za-z_][\w.]*)\)\s*==\s*"
        r"Brightness\.dark\s*\?\s*Colors\.white\s*:\s*Colors\.black8?7?", re.S),
     r"AppSemanticColors.onColor(\1)"),
]

GLOBAL = [
    # 危险色操作上的前景色
    ("""                        backgroundColor: AppSemanticColors.danger,
                        foregroundColor: Colors.white,""",
     """                        backgroundColor: AppSemanticColors.danger,
                        foregroundColor: AppSemanticColors.onColor(
                            AppSemanticColors.danger),"""),
    ("""            backgroundColor: AppSemanticColors.danger,
            foregroundColor: Colors.white,""",
     """            backgroundColor: AppSemanticColors.danger,
            foregroundColor:
                AppSemanticColors.onColor(AppSemanticColors.danger),"""),
    # 补打卡 FAB（warning 底）
    ("""                    backgroundColor: AppSemanticColors.warning,
                    foregroundColor: Colors.white,""",
     """                    backgroundColor: AppSemanticColors.warning,
                    foregroundColor: AppSemanticColors.onColor(
                        AppSemanticColors.warning),"""),
    # 图表点的白色描边 → 跟随图表底色
    ("""                            strokeWidth: 2,
                            strokeColor: Colors.white,""",
     """                            strokeWidth: 2,
                            strokeColor: colorScheme.surface,"""),
    # 取色矩阵的选中描边：白色在浅色块上不可见
    ("""                          border: Border.all(
                            color: currentColor == color
                                ? Colors.white
                                : Colors.transparent,
                            width: 2,
                          ),""",
     """                          border: Border.all(
                            color: currentColor == color
                                ? AppSemanticColors.onColor(color)
                                : Colors.transparent,
                            width: 2,
                          ),"""),
    # 临时分类默认色
    ("Category(name: nameController.text, color: Colors.grey);",
     "Category(\n                          name: nameController.text,\n                          color: AppSemanticColors.neutral);"),
    # 面板里的说明文字：固定灰在深色下读不清
    ("TextStyle(color: Colors.grey[600], fontSize: 11)),",
     "TextStyle(\n                            color: colorScheme.onSurfaceVariant,\n                            fontSize: 11)),"),
    ("style: TextStyle(color: Colors.grey[600]),",
     "style: TextStyle(color: colorScheme.onSurfaceVariant),"),
    # 拖拽占位区
    ("""                            color: isHovering
                                ? AppSemanticColors.warning.withValues(alpha: 0.3)
                                : Colors.grey.withValues(alpha: 0.15),""",
     """                            color: isHovering
                                ? AppSemanticColors.warning
                                    .withValues(alpha: 0.3)
                                : surfaces.subtle,"""),
    ("""                              color: isHovering ? AppSemanticColors.warning : Colors.grey,
                              width: 1,""",
     """                              color: isHovering
                                  ? AppSemanticColors.warning
                                  : surfaces.border,
                              width: 1,"""),
    ("""                              Icon(Icons.visibility_off,
                                  color:
                                      isHovering ? AppSemanticColors.warning : Colors.grey,
                                  size: 16),""",
     """                              Icon(Icons.visibility_off,
                                  color: isHovering
                                      ? AppSemanticColors.warning
                                      : colorScheme.onSurfaceVariant,
                                  size: 16),"""),
    ("""                                style: TextStyle(
                                  color:
                                      isHovering ? AppSemanticColors.warning : Colors.grey,
                                  fontSize: 12,
                                ),""",
     """                                style: TextStyle(
                                  color: isHovering
                                      ? AppSemanticColors.warning
                                      : colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),"""),
    # 已隐藏子事件 chip
    ("""                            avatar: const Icon(Icons.restore,
                                size: 14, color: Colors.grey),
                            label: Text(hiddenSubCat,
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12)),
                            backgroundColor: Colors.grey.withValues(alpha: 0.2),""",
     """                            avatar: Icon(Icons.restore,
                                size: 14, color: colorScheme.onSurfaceVariant),
                            label: Text(hiddenSubCat,
                                style: TextStyle(
                                    color: colorScheme.onSurfaceVariant,
                                    fontSize: 12)),
                            backgroundColor: surfaces.subtle,"""),
    ("""                            side: BorderSide(
                                color: Colors.grey.withValues(alpha: 0.4)),""",
     """                            side: BorderSide(color: surfaces.border),"""),
    # 目标卡删除图标
    ("color: Colors.redAccent),", "color: AppSemanticColors.danger),"),
]

BY_FILE = {
    "lib/screens/home_screen.dart": [
        # 分类弹窗：原先没有本地 colorScheme / surfaces
        ("""      {int? index, Category? existingCat}) {
    bool isEdit = index != null && existingCat != null;""",
         """      {int? index, Category? existingCat}) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    bool isEdit = index != null && existingCat != null;"""),
        # 模板管理弹窗
        ("""          builder: (context, setSheetState) {
            final templates = provider.templates;""",
         """          builder: (context, setSheetState) {
            final colorScheme = Theme.of(context).colorScheme;
            final templates = provider.templates;"""),
    ],
    # 饼图未触摸扇区的标题
    "lib/screens/travel_screen.dart": [
        ("""                            color: isTouched
                                ? colorScheme.onSurface
                                : Colors.white,""",
         """                            color: isTouched
                                ? colorScheme.onSurface
                                : AppSemanticColors.onColor(color),"""),
    ],
    # 时间点日历格
    "lib/widgets/target_stats_section.dart": [
        ("""      case TimePointStatus.onTime:
        bgColor = AppSemanticColors.success;
        textColor = Colors.white;
        break;
      case TimePointStatus.late:
        bgColor = AppSemanticColors.warning;
        textColor = Colors.white;
        break;""",
         """      case TimePointStatus.onTime:
        bgColor = AppSemanticColors.success;
        textColor = AppSemanticColors.onColor(bgColor);
        break;
      case TimePointStatus.late:
        bgColor = AppSemanticColors.warning;
        textColor = AppSemanticColors.onColor(bgColor);
        break;"""),
    ],
    # 选中切换项：primary 底应该配 onPrimary
    "lib/screens/profile_screen.dart": [
        ("""                          color: _showParentOnly
                              ? Colors.white
                              : colorScheme.onSurfaceVariant,""",
         """                          color: _showParentOnly
                              ? colorScheme.onPrimary
                              : colorScheme.onSurfaceVariant,"""),
    ],
    # 开始日期占位文字
    "lib/screens/add_check_in_goal_screen.dart": [
        ("""                style: TextStyle(
                  color: _startDate != null ? null : Colors.grey,
                ),""",
         """                style: TextStyle(
                  color: _startDate != null ? null : colorScheme.onSurfaceVariant,
                ),"""),
    ],
    # 语音面板说明文字
    "lib/widgets/voice_schedule_sheet.dart": [
        ("""              style: TextStyle(color: Colors.grey[600], fontSize: 13),""",
         """              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13),"""),
    ],
}


def add_import(text, quoted):
    line = "import %s;" % quoted
    if line in text:
        return text
    lines = text.split("\n")
    imports = [(i, l) for i, l in enumerate(lines) if l.startswith("import ")]
    if not imports:
        return text
    theme = [(i, l) for i, l in imports if "/theme/" in l]
    if theme:
        first = theme[0][0]
        drop = {i for i, _ in theme}
        merged = sorted([l for _, l in theme] + [line])
        tail = [l for i, l in enumerate(lines) if i >= first and i not in drop]
        return "\n".join(lines[:first] + merged + tail)
    last = imports[-1][0]
    lines.insert(last + 1, line)
    return "\n".join(lines)


def main():
    changed = []
    for base, _dirs, names in os.walk(os.path.join(ROOT, "lib")):
        for n in sorted(names):
            if not n.endswith(".dart"):
                continue
            full = os.path.join(base, n)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            if rel.startswith("lib/theme/"):
                continue
            src = open(full, encoding="utf-8").read()
            out = src
            for pattern, repl in GLOBAL_REGEX:
                out = pattern.sub(repl, out)
            for old, new in GLOBAL:
                out = out.replace(old, new)
            for old, new in BY_FILE.get(rel, []):
                if old not in out:
                    print("!! 未命中 %s: %r" % (rel, old.split("\n")[0][:70]))
                out = out.replace(old, new)
            if rel in IMPORTS:
                out = add_import(out, IMPORTS[rel])
            if out != src:
                open(full, "w", encoding="utf-8").write(out)
                changed.append(rel)
    print("改动 %d 个文件：" % len(changed))
    for rel in changed:
        print("  ", rel)


if __name__ == "__main__":
    main()
