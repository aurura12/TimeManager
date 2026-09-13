#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第三轮评审修复：半透明底的实际合成 + 同色系文字对比度。

两件事：
1. `onColor` 收到 alpha < 1 的输入时会算错（computeLuminance 忽略 alpha），
   调用点改成先 `AppSemanticColors.tint(color, surface, alpha)` 合成成不透明色。
2. "语义色文字压在同色淡底上"（状态徽标 / 奖牌圆点 / 统计卡 / 词云）改用
   `onTint` / `readableOn`，保持色相但把明度推到 ≥ 4.5:1。
"""
import os
import re

ROOT = os.path.normpath(os.path.dirname(os.path.abspath(__file__)) + "/..")

# 需要补 app_theme（AppSurfaces）
NEED_APP_THEME = {
    "lib/widgets/calendar_sync_status_badge.dart",
    "lib/screens/check_in_map_screen.dart",
    "lib/screens/target_detail_screen.dart",
    "lib/widgets/profile_settings_drawer.dart",
    "lib/screens/check_in_detail_screen.dart",
    "lib/widgets/target_stats_section.dart",
}

BY_FILE = {
    "lib/screens/home_screen.dart": [
        # 分类项：半透明底先合成成不透明色
        ("""    // 调色板里有浅色（芥末黄 / brandSurface），叠字必须按背景亮度取黑/白
    final subBg = cat.color.withValues(alpha: 0.6);
    final onSubBg = AppSemanticColors.onColor(subBg);
    final editBg = cat.color.withValues(alpha: 0.4);
    final onEditBg = AppSemanticColors.onColor(editBg);""",
         """    // 侧栏底下是 surfaces.subtle：半透明分类色要先合成，对比度才算得对
    final sidebarSurface = AppSurfaces.of(context).subtle;
    final subBg = AppSemanticColors.tint(cat.color, sidebarSurface, 0.6);
    final onSubBg = AppSemanticColors.onColor(subBg);
    final editBg = AppSemanticColors.tint(cat.color, sidebarSurface, 0.4);
    final onEditBg = AppSemanticColors.onColor(editBg);"""),
        # 可排序 chip：0.8 透明度的分类色
        ("""  Widget _buildChip(String item, int index) {
    return GestureDetector(""",
         """  Widget _buildChip(String item, int index) {
    // 半透明分类色先合成为不透明色，onColor 才不会比错
    final chipBg =
        AppSemanticColors.tint(widget.color, AppSurfaces.of(context).card, 0.8);
    return GestureDetector("""),
        ("""      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.color.withValues(alpha: 0.8),
        label: Text(item,
            style: TextStyle(
                color: AppSemanticColors.onColor(
                    widget.color.withValues(alpha: 0.8)),
                fontSize: 12)),""",
         """      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: chipBg,
        label: Text(item,
            style: TextStyle(
                color: AppSemanticColors.onColor(chipBg), fontSize: 12)),"""),
        # 三列列头的"今天"：同色系文字压在同色淡底
        ("""    final colorScheme = Theme.of(context).colorScheme;
    final today = _isToday;
    return SizedBox(
      height: _kDayHeaderHeight,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: today ? colorScheme.primary.withValues(alpha: 0.12) : null,
          borderRadius: AppRadius.badgeAll,
        ),
        child: Text(
          '${date.month}月${date.day}日 ${_kWeekdayLabels[date.weekday - 1]}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: today ? FontWeight.bold : FontWeight.w500,
            color: today ? colorScheme.primary : colorScheme.onSurfaceVariant,
          ),""",
         """    final colorScheme = Theme.of(context).colorScheme;
    final today = _isToday;
    final pageSurface = AppSurfaces.of(context).page;
    // primary 压在 12% primary 淡底上要压深才够对比
    final todayBg = AppSemanticColors.tint(colorScheme.primary, pageSurface, 0.12);
    final onTodayBg = AppSemanticColors.onTint(colorScheme.primary, pageSurface,
        alpha: 0.12);
    return SizedBox(
      height: _kDayHeaderHeight,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: today ? todayBg : null,
          borderRadius: AppRadius.badgeAll,
        ),
        child: Text(
          '${date.month}月${date.day}日 ${_kWeekdayLabels[date.weekday - 1]}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: today ? FontWeight.bold : FontWeight.w500,
            color: today ? onTodayBg : colorScheme.onSurfaceVariant,
          ),"""),
    ],
    "lib/widgets/target_stats_section.dart": [
        # 今日状态行：同色 15% 淡底 + 同色文字
        ("""  Widget _buildTimePointTodayRow(TimePointStatus status, ColorScheme colorScheme) {
    String text;
    Color color;""",
         """  Widget _buildTimePointTodayRow(TimePointStatus status, ColorScheme colorScheme) {
    final surface = AppSurfaces.of(context).card;
    String text;
    Color color;"""),
        ("""              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: AppRadius.gridAll,
              ),
              alignment: Alignment.center,
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),""",
         """              decoration: BoxDecoration(
                color: AppSemanticColors.tint(color, surface),
                borderRadius: AppRadius.gridAll,
              ),
              alignment: Alignment.center,
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  // 同色系文字压在同色淡底上会糊，压深到可读
                  color: AppSemanticColors.onTint(color, surface),
                ),
              ),"""),
    ],
    "lib/widgets/calendar_sync_status_badge.dart": [
        ("""        return Tooltip(
          message: tooltip,""",
         """        final surface = AppSurfaces.of(context).card;
        final badgeBg = AppSemanticColors.tint(color, surface, 0.12);
        final onBadge = AppSemanticColors.onTint(color, surface, alpha: 0.12);
        return Tooltip(
          message: tooltip,"""),
        ("""                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: AppRadius.cardAll,
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                ),""",
         """                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: AppRadius.cardAll,
                  border: Border.all(
                      color: AppSemanticColors.tint(color, surface, 0.35)),
                ),"""),
        ("""                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                        ),""",
         """                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: onBadge,
                        ),"""),
        ("""                      Icon(icon, size: 14, color: color),""",
         """                      Icon(icon, size: 14, color: onBadge),"""),
        ("""                        color: color.withValues(alpha: 0.95),""",
         """                        color: onBadge,"""),
    ],
    "lib/screens/check_in_map_screen.dart": [
        # 排名圆点：奖牌色 15% 淡底 + 同色数字
        ("""        leading: CircleAvatar(
          backgroundColor: rankColor.withValues(alpha: 0.15),
          child: Text(
            '$rank',
            style: TextStyle(fontWeight: FontWeight.bold, color: rankColor),
          ),
        ),""",
         """        leading: CircleAvatar(
          backgroundColor: AppSemanticColors.tint(rankColor, surface, 0.15),
          child: Text(
            '$rank',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppSemanticColors.onTint(rankColor, surface),
            ),
          ),
        ),"""),
        # 次数胶囊：primary 12% 淡底 + primary 文字
        ("""        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: AppRadius.controlAll,
          ),
          child: Text(
            '$count 次',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
        ),""",
         """        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppSemanticColors.tint(colorScheme.primary, surface, 0.12),
            borderRadius: AppRadius.controlAll,
          ),
          child: Text(
            '$count 次',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppSemanticColors.onTint(colorScheme.primary, surface,
                  alpha: 0.12),
            ),
          ),
        ),"""),
        # 卡片底面（Card 的 color）
        ("""    final rankColor = rank <= 3""",
         """    // 卡片底面：奖牌/主色都是压在它上面的
    final surface = colorScheme.surfaceContainerLow;
    final rankColor = rank <= 3"""),
    ],
    "lib/screens/target_detail_screen.dart": [
        ("""  Widget _buildTargetInfoCard(Target target, ColorScheme colorScheme) {
    final previewText = _getPreviewText(target);""",
         """  Widget _buildTargetInfoCard(Target target, ColorScheme colorScheme) {
    final surface = AppSurfaces.of(context).card;
    final iconBg = AppSemanticColors.tint(target.color, surface);
    final onIconBg = AppSemanticColors.onTint(target.color, surface);
    final previewText = _getPreviewText(target);"""),
        ("""              decoration: BoxDecoration(
                color: target.color.withValues(alpha: 0.15),
                borderRadius: AppRadius.controlAll,
              ),
              alignment: Alignment.center,
              child: Icon(
                _getTypeIcon(target.type),
                color: target.color,
                size: 24,
              ),""",
         """              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: AppRadius.controlAll,
              ),
              alignment: Alignment.center,
              child: Icon(
                _getTypeIcon(target.type),
                color: onIconBg,
                size: 24,
              ),"""),
    ],
    "lib/widgets/profile_settings_drawer.dart": [
        ("""    if (googleUser != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),""",
         """    if (googleUser != null) {
      final surface = AppSurfaces.of(context).card;
      final avatarBg = AppSemanticColors.tint(
          Theme.of(context).colorScheme.primary, surface, 0.12);
      final onAvatarBg = AppSemanticColors.onTint(
          Theme.of(context).colorScheme.primary, surface,
          alpha: 0.12);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),"""),
        ("""                CircleAvatar(
                  radius: 28,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.12),
                  backgroundImage: googleUser.photoUrl != null
                      ? NetworkImage(googleUser.photoUrl!)
                      : null,
                  child: googleUser.photoUrl == null
                      ? Icon(
                          Icons.person,
                          size: 28,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                ),""",
         """                CircleAvatar(
                  radius: 28,
                  backgroundColor: avatarBg,
                  backgroundImage: googleUser.photoUrl != null
                      ? NetworkImage(googleUser.photoUrl!)
                      : null,
                  child: googleUser.photoUrl == null
                      ? Icon(
                          Icons.person,
                          size: 28,
                          color: onAvatarBg,
                        )
                      : null,
                ),"""),
    ],
    "lib/widgets/schedule_sync_progress_banner.dart": [
        # 语义色文字/图标压在不透明底面上，先取可读版本
        ("""    final color = progress.isError
        ? colorScheme.error
        : progress.isFinished
            ? AppSemanticColors.success
            : colorScheme.primary;""",
         """    final color = progress.isError
        ? colorScheme.error
        : progress.isFinished
            ? AppSemanticColors.success
            : colorScheme.primary;
    // brand 绿在白底只有 2.2:1，当文字用要先压到可读
    final textColor = AppSemanticColors.readableOn(color, colorScheme.surface);"""),
        ("""                    size: 18,
                    color: color,
                  ),""",
         """                    size: 18,
                    color: textColor,
                  ),"""),
        ("""                  if (progressText != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      progressText,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],""",
         """                  if (progressText != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      progressText,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],"""),
        ("""                  color: color,
                  backgroundColor: color.withValues(alpha: 0.14),""",
         """                  color: color,
                  backgroundColor:
                      AppSemanticColors.tint(color, colorScheme.surface, 0.14),"""),
    ],
    "lib/screens/check_in_detail_screen.dart": [
        # 统计卡：语义色 10% 淡底 + 同色图标/文字
        ("""  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: AppRadius.cardAll,
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: color)),
          Text(label,
              style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8))),
        ],
      ),
    );
  }""",
         """  @override
  Widget build(BuildContext context) {
    final surface = AppSurfaces.of(context).page;
    final tinted = AppSemanticColors.tint(color, surface, 0.1);
    final onTinted = AppSemanticColors.onTint(color, surface, alpha: 0.1);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: tinted,
        borderRadius: AppRadius.cardAll,
      ),
      child: Column(
        children: [
          Icon(icon, color: onTinted, size: 22),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: onTinted)),
          Text(label,
              style: TextStyle(fontSize: 11, color: onTinted)),
        ],
      ),
    );
  }"""),
    ],
    "lib/screens/check_in_screen.dart": [
        # 目标卡上的「打卡」按钮：前景与底都是 onCardColor，底先合成
        ("""                        style: TextButton.styleFrom(
                          foregroundColor: onCardColor,
                          backgroundColor: onCardColor.withValues(alpha: 0.15),""",
         """                        style: TextButton.styleFrom(
                          foregroundColor: onCardColor,
                          backgroundColor: AppSemanticColors.tint(
                              onCardColor, cardColor, 0.15),"""),
    ],
    "lib/screens/word_cloud_screen.dart": [
        # 词云是文字，直接拿色板色在浅底上会糊
        ("""      // 词云统一使用语义图表色板，不再各自写色
      final color = AppSemanticColors
          .wordCloud[i % AppSemanticColors.wordCloud.length];""",
         """      // 词云统一使用语义图表色板；它是文字，要压到在底色上可读
      final color = AppSemanticColors.readableOn(
        AppSemanticColors.wordCloud[i % AppSemanticColors.wordCloud.length],
        Theme.of(context).colorScheme.surface,
      );"""),
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
            for old, new in BY_FILE.get(rel, []):
                if old not in out:
                    print("!! 未命中 %s: %r" % (rel, old.split("\n")[0][:70]))
                out = out.replace(old, new)
            if rel in NEED_APP_THEME and "AppSurfaces" in out:
                out = add_import(out, "'../theme/app_theme.dart'")
            if out != src:
                open(full, "w", encoding="utf-8").write(out)
                changed.append(rel)
    print("改动 %d 个文件：" % len(changed))
    for rel in changed:
        print("  ", rel)


if __name__ == "__main__":
    main()
