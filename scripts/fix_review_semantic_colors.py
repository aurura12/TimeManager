#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""评审修复：P1 实色块文字对比度 / P2 语义色落地与默认色集中化。

只做替换，不做目录级 format（原因见 docs/design-system.md 与记忆）。
"""
import os
import re

ROOT = os.path.normpath(os.path.dirname(os.path.abspath(__file__)) + "/..")

# ------------------------------------------------------------------ 导入
IMPORTS = {
    "lib/widgets/time_grid.dart": "'../theme/app_semantic_colors.dart'",
    "lib/main.dart": "'package:time_manager/theme/app_semantic_colors.dart'",
    "lib/screens/travel_screen.dart": "'../theme/app_semantic_colors.dart'",
    "lib/screens/app_log_screen.dart": "'../theme/app_semantic_colors.dart'",
    "lib/screens/target_screen.dart": "'../theme/app_semantic_colors.dart'",
    "lib/screens/target_detail_screen.dart": "'../theme/app_semantic_colors.dart'",
    "lib/models/category.dart": "'../theme/app_semantic_colors.dart'",
    "lib/models/check_in_goal.dart": "'../theme/app_semantic_colors.dart'",
}

# ------------------------------------------------------------------ 全局替换
GLOBAL = [
    # 图表色板：不再用 Colors.primaries
    ("Colors.primaries[index % Colors.primaries.length]",
     "AppSemanticColors.chartAt(index)"),
    ("Colors.primaries[i % Colors.primaries.length]",
     "AppSemanticColors.chartAt(i)"),
    # 状态色统一来源
    ("return Colors.orange.shade700;", "return AppSemanticColors.warning;"),
    ("color: Colors.orange.withValues(alpha: 0.2),",
     "color: AppSemanticColors.warning.withValues(alpha: 0.2),"),
    ("fontSize: 10, color: Colors.orange)),",
     "fontSize: 10, color: AppSemanticColors.warning)),"),
    ("size: 16, color: Colors.orange),",
     "size: 16, color: AppSemanticColors.warning),"),
    ("color = Colors.green;", "color = AppSemanticColors.success;"),
    ("bgColor = Colors.green;", "bgColor = AppSemanticColors.success;"),
    ("bgColor = Colors.orange;", "bgColor = AppSemanticColors.warning;"),
    # 危险色统一来源（AppSemanticColors.danger 是 const，const 上下文仍成立）
    ("leading: const Icon(Icons.delete_outline, color: Colors.red),",
     "leading: const Icon(Icons.delete_outline, color: AppSemanticColors.danger),"),
    ("title: const Text('删除', style: TextStyle(color: Colors.red)),",
     "title: const Text('删除', style: TextStyle(color: AppSemanticColors.danger)),"),
    ("TextButton.styleFrom(foregroundColor: Colors.red),",
     "TextButton.styleFrom(foregroundColor: AppSemanticColors.danger),"),
    ("size: 20, color: Colors.red),", "size: 20, color: AppSemanticColors.danger),"),
    ("child: Text('删除事件', style: TextStyle(color: Colors.red)),",
     "child: Text('删除事件', style: TextStyle(color: AppSemanticColors.danger)),"),
    ("child: const Text('确认', style: TextStyle(color: Colors.red)),",
     "child: const Text('确认', style: TextStyle(color: AppSemanticColors.danger)),"),
    # main.dart 兜底错误页
    ("const Icon(Icons.error_outline, size: 48, color: Colors.red),",
     "const Icon(Icons.error_outline, size: 48, color: AppSemanticColors.danger),"),
    ("style: const TextStyle(color: Colors.red)),",
     "style: const TextStyle(color: AppSemanticColors.danger)),"),
    # 默认选中色 / 取色器色相基准
    ("Color selectedColor = isEdit ? existingCat.color : Colors.blue;",
     "Color selectedColor =\n        isEdit ? existingCat.color : AppSemanticColors.palette.first;"),
    ("""    List<Color> hues = [
      Colors.red,
      Colors.orange,
      Colors.yellow,
      Colors.green,
      Colors.cyan,
      Colors.blue,
      Colors.purple,
      Colors.pink,
    ];""",
     """    // 分类自定义颜色的色相基准，集中在语义色文件里
    final hues = AppSemanticColors.pickerHues;"""),
    # 待同步小红点 / 远程日程标记
    ("color: remoteViewEnabled ? Colors.blue : null,",
     "color: remoteViewEnabled ? AppSemanticColors.info : null,"),
    ("size: 12, color: Colors.blue),", "size: 12, color: AppSemanticColors.info),"),
]

# ------------------------------------------------------------------ 按文件替换
BY_FILE = {
    "lib/widgets/time_grid.dart": [
        ("                      style: AppText.gridLabel.copyWith(color: Colors.white),",
         """                      style: AppText.gridLabel.copyWith(
                        // 高亮时底色是主色半透明，未高亮时是分类实色
                        color: highlighted
                            ? colorScheme.onSurface
                            : AppSemanticColors.onColor(slot.color!),
                      ),"""),
    ],
    "lib/screens/home_screen.dart": [
        # 分类块内共用的前景色（背景是用户可选色，必须按亮度取黑/白）
        ("""  Widget _buildCategoryItem(int catIndex, Category cat, TimeProvider provider) {
    bool isExpanded = provider.getCategoryExpandState(cat.id);
    bool isTemporary = cat.name == TimeProvider.temporaryCategoryName;
""",
         """  Widget _buildCategoryItem(int catIndex, Category cat, TimeProvider provider) {
    bool isExpanded = provider.getCategoryExpandState(cat.id);
    bool isTemporary = cat.name == TimeProvider.temporaryCategoryName;
    // 调色板里有浅色（芥末黄 / brandSurface），叠字必须按背景亮度取黑/白
    final subBg = cat.color.withValues(alpha: 0.6);
    final onSubBg = AppSemanticColors.onColor(subBg);
    final editBg = cat.color.withValues(alpha: 0.4);
    final onEditBg = AppSemanticColors.onColor(editBg);
"""),
        # 分类名
        ("""                    child: Text(
                      cat.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),""",
         """                    child: Text(
                      cat.name,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppSemanticColors.onColor(cat.color),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),"""),
        # 子分类条
        ("""                      decoration: BoxDecoration(
                        color: cat.color.withValues(alpha: 0.6),
                        borderRadius: AppRadius.gridAll,
                        border: Border.all(
                          color: Colors.white,
                          width: 1,
                        ),
                      ),""",
         """                      decoration: BoxDecoration(
                        color: subBg,
                        borderRadius: AppRadius.gridAll,
                        border: Border.all(
                          color: AppSemanticColors.onColorMuted(subBg),
                          width: 1,
                        ),
                      ),"""),
        ("""                            child: Text(
                              subCat,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),""",
         """                            child: Text(
                              subCat,
                              style: TextStyle(
                                color: onSubBg,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),"""),
        # 「编辑」块
        ("""                    decoration: BoxDecoration(
                      color: cat.color.withValues(alpha: 0.4),
                      borderRadius: AppRadius.gridAll,
                      border: Border.all(color: Colors.white, width: 1),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.edit, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text('编辑',
                            style:
                                TextStyle(color: Colors.white, fontSize: 11)),
                      ],
                    ),""",
         """                    decoration: BoxDecoration(
                      color: editBg,
                      borderRadius: AppRadius.gridAll,
                      border: Border.all(
                        color: AppSemanticColors.onColorMuted(editBg),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.edit, color: onEditBg, size: 14),
                        const SizedBox(width: 4),
                        Text('编辑',
                            style: TextStyle(color: onEditBg, fontSize: 11)),
                      ],
                    ),"""),
        # 折叠按钮图标叠在侧栏次级底色上，不能用白
        ("""        child: Icon(
          widget.isExpanded ? Icons.expand_less : Icons.expand_more,
          color: Colors.white,
          size: 16,
        ),""",
         """        child: Icon(
          widget.isExpanded ? Icons.expand_less : Icons.expand_more,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 16,
        ),"""),
        # 分类 chip
        ("""      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.color.withValues(alpha: 0.8),
        label: Text(item,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.badgeAll),
        side: BorderSide.none,
      ),
    );
  }

  Widget _buildFeedback(String item) {
    return Material(
      elevation: 8.0,
      borderRadius: AppRadius.badgeAll,
      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.color,
        label: Text(item,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.badgeAll),
        side: BorderSide.none,
      ),
    );
  }""",
         """      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.color.withValues(alpha: 0.8),
        label: Text(item,
            style: TextStyle(
                color: AppSemanticColors.onColor(
                    widget.color.withValues(alpha: 0.8)),
                fontSize: 12)),
        shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.badgeAll),
        side: BorderSide.none,
      ),
    );
  }

  Widget _buildFeedback(String item) {
    return Material(
      elevation: 8.0,
      borderRadius: AppRadius.badgeAll,
      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.color,
        label: Text(item,
            style: TextStyle(
                color: AppSemanticColors.onColor(widget.color),
                fontSize: 12)),
        shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.badgeAll),
        side: BorderSide.none,
      ),
    );
  }"""),
        ("color: Colors.orange,", "color: AppSemanticColors.warning,"),
    ],
    "lib/screens/profile_screen.dart": [
        ("""                    titleStyle: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                        color: isTouched ? colorScheme.onSurface : Colors.white),""",
         """                    titleStyle: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                        color: isTouched
                            ? colorScheme.onSurface
                            : AppSemanticColors.onColor(color)),"""),
    ],
    "lib/screens/travel_screen.dart": [
        ("""                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),""",
         """                        decoration: const BoxDecoration(
                          color: AppSemanticColors.success,
                          shape: BoxShape.circle,
                        ),"""),
        ("accentColor: Colors.blue,", "accentColor: AppSemanticColors.info,"),
    ],
    "lib/widgets/check_in_map_preview.dart": [
        ("""          child: Text(
            count > 1 ? '$count' : '',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),""",
         """          child: Text(
            count > 1 ? '$count' : '',
            style: TextStyle(
              color: AppSemanticColors.onColor(color),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),"""),
    ],
    "lib/screens/add_target_screen.dart": [
        ("""                child: _selectedColor == _themeColors[index]
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,""",
         """                child: _selectedColor == _themeColors[index]
                    ? Icon(Icons.check,
                        size: 16,
                        color: AppSemanticColors.onColor(_themeColors[index]))
                    : null,"""),
    ],
    "lib/screens/add_check_in_goal_screen.dart": [
        ("""                  child: selected
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : null,""",
         """                  child: selected
                      ? Icon(Icons.check,
                          color: AppSemanticColors.onColor(_themeColors[i]),
                          size: 18)
                      : null,"""),
        ("""    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color,
        borderRadius: AppRadius.cardAll,
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: AppRadius.cardAll,
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_period.label} ${_countController.text.isEmpty ? "1" : _countController.text} 次',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),""",
         """    final onColor = AppSemanticColors.onColor(color);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color,
        borderRadius: AppRadius.cardAll,
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: onColor.withValues(alpha: 0.2),
              borderRadius: AppRadius.cardAll,
            ),
            child: Icon(icon, color: onColor, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: onColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_period.label} ${_countController.text.isEmpty ? "1" : _countController.text} 次',
                  style: TextStyle(
                    fontSize: 13,
                    color: onColor.withValues(alpha: 0.85),
                  ),
                ),"""),
    ],
    "lib/widgets/target_stats_section.dart": [
        ("color: progress > 0.5 ? Colors.white : colorScheme.onSurface,",
         """color: progress > 0.5
                            ? AppSemanticColors.onColor(colorScheme.primary)
                            : colorScheme.onSurface,"""),
        ("color: isCompleted ? Colors.white : colorScheme.onSurfaceVariant,",
         """color: isCompleted
              ? AppSemanticColors.onColor(colorScheme.primary)
              : colorScheme.onSurfaceVariant,"""),
        ("                final progress = maxDays > 0 ? streak.days / maxDays : 0.0;",
         """                final progress = maxDays > 0 ? streak.days / maxDays : 0.0;
                final barColor = streak.days >= 7
                    ? colorScheme.primary
                    : colorScheme.secondary;"""),
        ("""                                decoration: BoxDecoration(
                                  color: streak.days >= 7 ? colorScheme.primary : colorScheme.secondary,
                                  borderRadius: AppRadius.gridAll,
                                ),""",
         """                                decoration: BoxDecoration(
                                  color: barColor,
                                  borderRadius: AppRadius.gridAll,
                                ),"""),
        ("color: progress > 0.3 ? Colors.white : colorScheme.onSurface,",
         """color: progress > 0.3
                                      ? AppSemanticColors.onColor(barColor)
                                      : colorScheme.onSurface,"""),
        # tooltip 显式给背景，白字才有对比
        ("""                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touchedSpots) {""",
         """                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => colorScheme.inverseSurface,
                      getTooltipItems: (touchedSpots) {"""),
        ("""                            TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),""",
         """                            TextStyle(
                              color: colorScheme.onInverseSurface,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),"""),
        ("""                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {""",
         """                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => colorScheme.inverseSurface,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {"""),
        ("""                          TextStyle(color: Colors.white, fontWeight: FontWeight.bold),""",
         """                          TextStyle(
                              color: colorScheme.onInverseSurface,
                              fontWeight: FontWeight.bold),"""),
    ],
    # 模型默认色集中化
    "lib/models/category.dart": [
        ("color: Color((map['color'] as num?)?.toInt() ?? 0xFF9E9E9E),",
         """color: Color((map['color'] as num?)?.toInt() ??
          AppSemanticColors.neutral.toARGB32()),"""),
    ],
    "lib/models/check_in_goal.dart": [
        ("color: Color(json['color'] as int? ?? 0xFF96B462),",
         """color: Color(json['color'] as int? ??
          AppSemanticColors.brandSurface.toARGB32()),"""),
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
        out = lines[:first] + merged + tail
        return "\n".join(out)
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
