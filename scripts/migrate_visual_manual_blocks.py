#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 4 项「统一视觉系统」手工改动集（无格式化版本）。

`dart format lib` 会按 Dart 3.12 的新风格重排整个仓库（HEAD 版本全部不符合新格式化器），
会把 diff 冲得没法 review。所以这里把手写改动固化成可重放的替换块，
在 HEAD 原始文本上重放，产出"只含语义改动"的版本。
"""
import re

BLOCKS = {
    "lib/screens/home_screen.dart": [
        # 主题导入
        ("""import '../providers/time_provider.dart';
import '../widgets/date_picker_panel.dart';
""",
         """import '../providers/time_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/date_picker_panel.dart';
"""),
        # 抽取 surfaces
        ("""    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
""",
         """    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);

    return Scaffold(
"""),
        # AppBar：底色/前景色交回主题
        ("""      appBar: AppBar(
        backgroundColor: isDark ? colorScheme.surface : const Color(0xFF9CB86A),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 8,
        // 仅 Windows：切换日期的按钮居中；安卓保持默认左对齐
        centerTitle: isDesktopPlatform,
        actionsPadding: const EdgeInsets.only(right: 15),
""",
         """      appBar: AppBar(
        // 底色、图标色、底部弱边框统一由主题给定，不再使用大面积橄榄绿
        titleSpacing: AppSpacing.sm,
        // 仅 Windows：切换日期的按钮居中；安卓保持默认左对齐
        centerTitle: isDesktopPlatform,
        actionsPadding: const EdgeInsets.only(right: AppSpacing.lg),
"""),
        # 同步进度条
        ("""                    return const LinearProgressIndicator(
                      backgroundColor: Colors.transparent,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFF9CB86A)),
                      minHeight: 3,
                    );
""",
         """                    return LinearProgressIndicator(
                      backgroundColor: Colors.transparent,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(colorScheme.primary),
                      minHeight: 3,
                    );
"""),
        # 三列分割线
        ("""                                      Expanded(
                                          child: _DayHeader(date: prevDate)),
                                      const VerticalDivider(
                                        width: 1,
                                        thickness: 1,
                                        color: Color(0x33000000),
                                      ),
                                      Expanded(
                                          child: _DayHeader(date: currentDate)),
                                      const VerticalDivider(
                                        width: 1,
                                        thickness: 1,
                                        color: Color(0x33000000),
                                      ),
                                      Expanded(
                                          child: _DayHeader(date: nextDate)),
""",
         """                                      Expanded(
                                          child: _DayHeader(date: prevDate)),
                                      VerticalDivider(
                                        width: 1,
                                        thickness: 1,
                                        color: surfaces.joinDivider,
                                      ),
                                      Expanded(
                                          child: _DayHeader(date: currentDate)),
                                      VerticalDivider(
                                        width: 1,
                                        thickness: 1,
                                        color: surfaces.joinDivider,
                                      ),
                                      Expanded(
                                          child: _DayHeader(date: nextDate)),
"""),
        ("""                                        ),
                                        const VerticalDivider(
                                          width: 1,
                                          thickness: 1,
                                          color: Color(0x33000000),
                                        ),
                                        Expanded(
                                          child: _DayGrid(
                                            date: currentDate,
""",
         """                                        ),
                                        VerticalDivider(
                                          width: 1,
                                          thickness: 1,
                                          color: surfaces.joinDivider,
                                        ),
                                        Expanded(
                                          child: _DayGrid(
                                            date: currentDate,
"""),
        ("""                                        ),
                                        const VerticalDivider(
                                          width: 1,
                                          thickness: 1,
                                          color: Color(0x33000000),
                                        ),
                                        Expanded(
                                          child: _DayGrid(
                                            date: nextDate,
""",
         """                                        ),
                                        VerticalDivider(
                                          width: 1,
                                          thickness: 1,
                                          color: surfaces.joinDivider,
                                        ),
                                        Expanded(
                                          child: _DayGrid(
                                            date: nextDate,
"""),
        # 时间轴 + 侧栏底色
        ("""  Widget _buildTimeLabelRow(int h) {
    return Container(
      width: 55,
      height: 45,
      alignment: Alignment.center,
      child: Text(
        "${h.toString().padLeft(2, '0')}:00",
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      ),
    );
  }

  Widget _buildCategorySidebar(TimeProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: 100,
      color: isDark ? colorScheme.surfaceContainerLow : Colors.grey[100],
""",
         """  Widget _buildTimeLabelRow(int h) {
    return Container(
      width: AppSizes.gridTimeAxis,
      height: AppSizes.gridRow,
      alignment: Alignment.center,
      child: Text(
        "${h.toString().padLeft(2, '0')}:00",
        style: AppText.gridLabel.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildCategorySidebar(TimeProvider provider) {
    final surfaces = AppSurfaces.of(context);

    return Container(
      width: 100,
      color: surfaces.subtle,
"""),
        # 侧栏底部添加按钮
        ("""              footer: Padding(
                padding: const EdgeInsets.all(8.0),
                child: ElevatedButton(
                  onPressed: () =>
                      _showCategoryDialog(context, provider), // 调用通用对话框（添加模式）
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    backgroundColor: isDark
                        ? colorScheme.surfaceContainerHighest
                        : Colors.white,
                    foregroundColor:
                        isDark ? colorScheme.onSurface : Colors.grey[700],
                    elevation: 0,
                    side: BorderSide(color: colorScheme.outlineVariant),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Icon(Icons.add, size: 24),
                ),
              ),
""",
         """              footer: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: OutlinedButton(
                  onPressed: () =>
                      _showCategoryDialog(context, provider), // 调用通用对话框（添加模式）
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    backgroundColor: surfaces.card,
                    side: BorderSide(color: surfaces.border),
                    shape: const RoundedRectangleBorder(
                        borderRadius: AppRadius.controlAll),
                  ),
                  child: const Icon(Icons.add, size: 24),
                ),
              ),
"""),
        # 左滑删除 = 统一危险色
        ("""                        backgroundColor: const Color(0xFFFE4A49),
                        foregroundColor: Colors.white,
                        icon: Icons.delete,
                        label: '删除',
                        borderRadius: BorderRadius.circular(6),
""",
         """                        backgroundColor: AppSemanticColors.danger,
                        foregroundColor: Colors.white,
                        icon: Icons.delete,
                        label: '删除',
                        borderRadius: AppRadius.badgeAll,
"""),
        # 分类块圆角
        ("""                    decoration: BoxDecoration(
                      color: cat.color,
                      borderRadius: BorderRadius.circular(6),
                    ),
""",
         """                    decoration: BoxDecoration(
                      color: cat.color,
                      borderRadius: AppRadius.badgeAll,
                    ),
"""),
        ("""                      decoration: BoxDecoration(
                        color: cat.color.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
""",
         """                      decoration: BoxDecoration(
                        color: cat.color.withValues(alpha: 0.6),
                        borderRadius: AppRadius.gridAll,
"""),
        ("""                    decoration: BoxDecoration(
                      color: cat.color.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
""",
         """                    decoration: BoxDecoration(
                      color: cat.color.withValues(alpha: 0.4),
                      borderRadius: AppRadius.gridAll,
"""),
        # 弹窗圆角交回主题
        ("""          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
""",
         """          return AlertDialog(
"""),
        # 隐藏拖拽区
        ("""                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isHovering ? Colors.orange : Colors.grey,
""",
         """                            borderRadius: AppRadius.controlAll,
                            border: Border.all(
                              color: isHovering ? Colors.orange : Colors.grey,
"""),
        # 已隐藏子事件 chip
        ("""                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
""",
         """                            shape: const RoundedRectangleBorder(
                                borderRadius: AppRadius.badgeAll),
"""),
        # 取色块
        ("""                          borderRadius: BorderRadius.circular(3),
                        ),
""",
         """                          borderRadius: AppRadius.gridAll,
                        ),
"""),
        # 分类弹窗确定按钮
        ("""              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9CB86A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
""",
         """              ElevatedButton(
"""),
        # 子事件添加图标
        ("""                        IconButton(
                          icon: const Icon(Icons.add_circle,
                              color: Color(0xFF9CB86A)),
""",
         """                        IconButton(
                          icon: Icon(Icons.add_circle,
                              color: Theme.of(context).colorScheme.primary),
"""),
        # 日期导航下划线
        ("""  Widget _buildAppBarDateNav(TimeProvider provider, DateTime date) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
""",
         """  Widget _buildAppBarDateNav(TimeProvider provider, DateTime date) {
    final colorScheme = Theme.of(context).colorScheme;
"""),
        ("""            style: TextStyle(
              decoration: TextDecoration.underline,
              decorationColor:
                  isDark ? colorScheme.onSurfaceVariant : Colors.white70,
            ),
""",
         """            style: TextStyle(
              decoration: TextDecoration.underline,
              decorationColor: colorScheme.onSurfaceVariant,
            ),
"""),
        # 复制昨天 / 应用模板 / 保存模板 / 重命名模板：主操作色交回主题
        ("""          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9CB86A),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              provider.copyFromYesterday(mode: ApplyTemplateMode.replaceAll);
              Navigator.pop(context);
            },
""",
         """          ElevatedButton(
            onPressed: () {
              provider.copyFromYesterday(mode: ApplyTemplateMode.replaceAll);
              Navigator.pop(context);
            },
"""),
        ("""          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9CB86A),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              provider.applyTemplate(template.id, ApplyTemplateMode.replaceAll);
              Navigator.pop(context);
            },
""",
         """          ElevatedButton(
            onPressed: () {
              provider.applyTemplate(template.id, ApplyTemplateMode.replaceAll);
              Navigator.pop(context);
            },
"""),
        ("""                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF9CB86A),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
""",
         """                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
"""),
        ("""          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9CB86A),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final ok =
                  provider.saveTemplateFromCurrentDay(nameController.text);
""",
         """          ElevatedButton(
            onPressed: () {
              final ok =
                  provider.saveTemplateFromCurrentDay(nameController.text);
"""),
        ("""          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9CB86A),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              provider.renameTemplate(template.id, nameController.text);
""",
         """          ElevatedButton(
            onPressed: () {
              provider.renameTemplate(template.id, nameController.text);
"""),
        # 三列列头
        ("""  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final today = _isToday;
    return SizedBox(
      height: _kDayHeaderHeight,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: today ? colorScheme.primary.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '${date.month}月${date.day}日 ${_kWeekdayLabels[date.weekday - 1]}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: today ? FontWeight.bold : FontWeight.w500,
            color: today
                ? colorScheme.primary
                : (isDark ? colorScheme.onSurfaceVariant : Colors.black87),
          ),
""",
         """  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
          ),
"""),
        # 分类 chip
        ("""      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.color.withValues(alpha: 0.8),
        label: Text(item,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),
    );
  }

  Widget _buildFeedback(String item) {
    return Material(
      elevation: 8.0,
      borderRadius: BorderRadius.circular(8),
      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.color,
        label: Text(item,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),
    );
  }
""",
         """      child: Chip(
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
  }
"""),
    ],
    "lib/screens/main_screen.dart": [
        ("""import '../services/on_this_day_service.dart';
import '../utils/adaptive.dart';
""",
         """import '../services/on_this_day_service.dart';
import '../theme/app_theme.dart';
import '../utils/adaptive.dart';
"""),
        ("""import 'travel_screen.dart';
""",
         """import 'travel_screen.dart';

/// 底部导航 / 侧边导航的一项。图标分选中态与未选中态，
/// 保证浅色、深色下选中状态都清晰。
class _NavEntry {
  const _NavEntry({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}
"""),
        ("""  static final List<BottomNavigationBarItem> _navItems =
      <BottomNavigationBarItem>[
    const BottomNavigationBarItem(icon: Icon(Icons.home), label: '记录'),
    const BottomNavigationBarItem(
      icon: Icon(Icons.menu_book_outlined),
      label: '日记',
    ),
    const BottomNavigationBarItem(icon: Icon(Icons.card_travel), label: '出行'),
    const BottomNavigationBarItem(
      icon: Icon(Icons.check_circle_outline),
      label: '打卡',
    ),
    const BottomNavigationBarItem(icon: Icon(Icons.flag), label: '目标'),
    const BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
  ];
""",
         """  static final List<_NavEntry> _navItems = <_NavEntry>[
    const _NavEntry(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      label: '记录',
    ),
    const _NavEntry(
      icon: Icons.menu_book_outlined,
      selectedIcon: Icons.menu_book,
      label: '日记',
    ),
    const _NavEntry(
      icon: Icons.card_travel_outlined,
      selectedIcon: Icons.card_travel,
      label: '出行',
    ),
    const _NavEntry(
      icon: Icons.check_circle_outline,
      selectedIcon: Icons.check_circle,
      label: '打卡',
    ),
    const _NavEntry(
      icon: Icons.flag_outlined,
      selectedIcon: Icons.flag,
      label: '目标',
    ),
    const _NavEntry(
      icon: Icons.person_outline,
      selectedIcon: Icons.person,
      label: '我的',
    ),
  ];
"""),
        ("""    final colorScheme = Theme.of(context).colorScheme;
    // Windows 上隐藏"目标"tab，安卓保持完整 6 个 tab
    final List<Widget> options = List.of(_widgetOptions);
    final List<BottomNavigationBarItem> items = List.of(_navItems);
""",
         """    final surfaces = AppSurfaces.of(context);
    // Windows 上隐藏"目标"tab，安卓保持完整 6 个 tab
    final List<Widget> options = List.of(_widgetOptions);
    final List<_NavEntry> items = List.of(_navItems);
"""),
        ("""                  NavigationRailDestination(
                    icon: item.icon,
                    selectedIcon: item.activeIcon,
                    label: Text(item.label ?? ''),
                  ),
""",
         """                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.selectedIcon),
                    label: Text(item.label),
                  ),
"""),
        ("""            const VerticalDivider(width: 1, thickness: 1),
""",
         """            VerticalDivider(
              width: 1,
              thickness: 1,
              color: surfaces.border,
            ),
"""),
        ("""      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
        items: items,
        currentIndex: safeIndex,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        onTap: _onItemTapped,
      ),
""",
         """      // 顶部一条弱边框，和内容区拉开层级（颜色与圆角统一走主题）
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: surfaces.panel,
          border: Border(top: BorderSide(color: surfaces.border)),
        ),
        child: NavigationBar(
          selectedIndex: safeIndex,
          onDestinationSelected: _onItemTapped,
          destinations: [
            for (final item in items)
              NavigationDestination(
                icon: Icon(item.icon),
                selectedIcon: Icon(item.selectedIcon),
                label: item.label,
                tooltip: item.label,
              ),
          ],
        ),
      ),
"""),
    ],
    "lib/widgets/time_grid.dart": [
        ("""import '../providers/time_provider.dart';
import '../utils/time_slot_segment.dart';
""",
         """import '../providers/time_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/time_slot_segment.dart';
"""),
        ("""          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: 24,
          itemExtent: 45,
""",
         """          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          itemCount: 24,
          itemExtent: AppSizes.gridRow,
"""),
        ("""    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final highlightColor = colorScheme.primary.withValues(alpha: 0.28);
    final emptyCellColor = isDark
        ? colorScheme.surfaceContainerHigh
        : const Color.fromARGB(255, 188, 186, 186);
""",
         """    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final highlightColor = colorScheme.primary.withValues(alpha: 0.28);
    // 空白格用主题的次级表面色，浅色下比原灰色更浅，深色下不刺眼
    final emptyCellColor = surfaces.gridEmpty;
"""),
        ("""    return Container(
      height: 45,
      padding: const EdgeInsets.symmetric(vertical: 1),
""",
         """    return Container(
      height: AppSizes.gridRow,
      padding: const EdgeInsets.symmetric(vertical: 1),
"""),
        ("""                  child: Center(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
""",
         """                  child: Center(
                    child: Text(
                      label,
                      style: AppText.gridLabel.copyWith(color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
"""),
        ("""                  decoration: BoxDecoration(
                    color: highlighted ? highlightColor : emptyCellColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
""",
         """                  decoration: BoxDecoration(
                    color: highlighted ? highlightColor : emptyCellColor,
                    borderRadius: AppRadius.gridAll,
                  ),
"""),
        ("""    if (isHighlighted) return BorderRadius.circular(4);
""",
         """    if (isHighlighted) return AppRadius.gridAll;
"""),
        ("""    return BorderRadius.only(
      topLeft: leftRounded ? const Radius.circular(4) : Radius.zero,
      bottomLeft: leftRounded ? const Radius.circular(4) : Radius.zero,
      topRight: rightRounded ? const Radius.circular(4) : Radius.zero,
      bottomRight: rightRounded ? const Radius.circular(4) : Radius.zero,
    );
""",
         """    // 相接的一侧圆角必须为 0（AppRadius.joined），否则连续时间块会出现缺口
    return BorderRadius.only(
      topLeft: leftRounded ? AppRadius.rGrid : AppRadius.rJoined,
      bottomLeft: leftRounded ? AppRadius.rGrid : AppRadius.rJoined,
      topRight: rightRounded ? AppRadius.rGrid : AppRadius.rJoined,
      bottomRight: rightRounded ? AppRadius.rGrid : AppRadius.rJoined,
    );
"""),
    ],
    "lib/widgets/template_bar.dart": [
        ("""import '../providers/time_provider.dart';
""",
         """import '../providers/time_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
"""),
        ("""  static const double _chipHeight = 30;
  static const double _chipGap = 3;
""",
         """  static const double _chipHeight = AppSizes.chip;
  static const double _chipGap = AppSpacing.xs;
"""),
        ("""    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chipCount = templates.length + 1;
""",
         """    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final chipCount = templates.length + 1;
"""),
        ("""      decoration: BoxDecoration(
        color: isDark ? colorScheme.surfaceContainerHigh : Colors.grey[200],
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
""",
         """      decoration: BoxDecoration(
        color: surfaces.subtle,
        border: Border(bottom: BorderSide(color: surfaces.border)),
      ),
"""),
        ("""              Text(
                '模板',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? colorScheme.onSurface : Colors.grey[800],
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onManageTap,
                icon: Icon(
                  Icons.settings,
                  size: 22,
                  color:
                      isDark ? colorScheme.onSurfaceVariant : Colors.grey[700],
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: '管理模板',
              ),
""",
         """              Text(
                '模板',
                style: AppText.body.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onManageTap,
                icon: const Icon(Icons.settings, size: 22),
                color: colorScheme.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: '管理模板',
              ),
"""),
        ("""              child: Material(
                color: isDark ? colorScheme.secondaryContainer : Colors.white,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: onVoiceTap,
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: _chipHeight,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.mic_none,
                          size: 16,
                          color: isDark
                              ? colorScheme.onSecondaryContainer
                              : colorScheme.primary,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '语音添加',
                          style: TextStyle(
                            color: isDark
                                ? colorScheme.onSecondaryContainer
                                : colorScheme.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
""",
         """              child: Material(
                color: surfaces.card,
                borderRadius: AppRadius.badgeAll,
                child: InkWell(
                  onTap: onVoiceTap,
                  borderRadius: AppRadius.badgeAll,
                  child: SizedBox(
                    height: _chipHeight,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.mic_none,
                          size: 16,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '语音添加',
                          style: AppText.badge.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
"""),
        ("""                decoration: BoxDecoration(
                  color: isDark
                      ? colorScheme.surfaceContainerHighest
                      : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Text(
                  '添加模板',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? colorScheme.onSurfaceVariant
                        : Colors.grey[700],
                  ),
                ),
""",
         """                decoration: BoxDecoration(
                  color: surfaces.card,
                  borderRadius: AppRadius.badgeAll,
                  border: Border.all(color: surfaces.border),
                ),
                child: Text(
                  '添加模板',
                  style: AppText.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
"""),
        ("""    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Tooltip(
      message: name,
      child: Material(
        color: isDark ? colorScheme.primaryContainer : const Color(0xFF9CB86A),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: TemplateBar._chipHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark ? colorScheme.onPrimaryContainer : Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
""",
         """    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: name,
      child: Material(
        // 模板 chip 统一用 primaryContainer，浅色/深色一致，不再各写一套
        color: colorScheme.primaryContainer,
        borderRadius: AppRadius.badgeAll,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.badgeAll,
          child: Container(
            height: TemplateBar._chipHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.badge.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
"""),
    ],
    "lib/screens/check_in_screen.dart": [
        ("""import '../services/check_in_sync_service.dart';
""",
         """import '../services/check_in_sync_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
"""),
        ("""    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('打卡', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        backgroundColor: isDark ? colorScheme.surface : const Color(0xFF96B462),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: [
""",
         """    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('打卡'),
        centerTitle: true,
        actions: [
"""),
        ("""              child: _buildBody(colorScheme, isDark),
""",
         """              child: _buildBody(colorScheme),
"""),
        ("""  Widget _buildBody(ColorScheme colorScheme, bool isDark) {
""",
         """  Widget _buildBody(ColorScheme colorScheme) {
"""),
        ("""        _buildSummaryCard(colorScheme, isDark, records.length),
""",
         """        _buildSummaryCard(colorScheme, records.length),
"""),
        ("""            (goal) => _buildGoalCard(goal, colorScheme, isDark, userId),
""",
         """            (goal) => _buildGoalCard(goal, colorScheme, userId),
"""),
        ("""      ColorScheme colorScheme, bool isDark, int recordCount) {
""",
         """      ColorScheme colorScheme, int recordCount) {
"""),
        ("""      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [colorScheme.primaryContainer, colorScheme.surfaceContainerHigh]
              : [const Color(0xFF96B462), const Color(0xFF7FA34E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SummaryItem(
              label: '打卡次数',
              value: '$recordCount',
              unit: '次',
              textColor: isDark ? colorScheme.onPrimaryContainer : Colors.white,
            ),
          ),
          _divider(isDark, colorScheme),
          Expanded(
            child: _SummaryItem(
              label: '最长连续',
              value: '$maxStreak',
              unit: '天',
              textColor: isDark ? colorScheme.onPrimaryContainer : Colors.white,
            ),
          ),
          _divider(isDark, colorScheme),
          Expanded(
            child: _SummaryItem(
              label: '目标数',
              value: '${_filteredGoals.length}',
              unit: '个',
              textColor: isDark ? colorScheme.onPrimaryContainer : Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(bool isDark, ColorScheme colorScheme) {
    return Container(
      width: 1,
      height: 40,
      color: (isDark ? colorScheme.onPrimaryContainer : Colors.white)
          .withValues(alpha: 0.3),
    );
  }
""",
         """      decoration: BoxDecoration(
        // 统计卡片统一用 primaryContainer，浅色/深色同一套，不再各写一套绿
        gradient: LinearGradient(
          colors: [
            colorScheme.primaryContainer,
            Color.lerp(
              colorScheme.primaryContainer,
              colorScheme.primary,
              0.35,
            )!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: AppRadius.sheetAll,
      ),
      child: Row(
        children: [
          Expanded(
            child: _SummaryItem(
              label: '打卡次数',
              value: '$recordCount',
              unit: '次',
              textColor: colorScheme.onPrimaryContainer,
            ),
          ),
          _divider(colorScheme),
          Expanded(
            child: _SummaryItem(
              label: '最长连续',
              value: '$maxStreak',
              unit: '天',
              textColor: colorScheme.onPrimaryContainer,
            ),
          ),
          _divider(colorScheme),
          Expanded(
            child: _SummaryItem(
              label: '目标数',
              value: '${_filteredGoals.length}',
              unit: '个',
              textColor: colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(ColorScheme colorScheme) {
    return Container(
      width: 1,
      height: 40,
      color: colorScheme.onPrimaryContainer.withValues(alpha: 0.3),
    );
  }
"""),
        ("""  Widget _buildGoalCard(
    CheckInGoal goal,
    ColorScheme colorScheme,
    bool isDark,
    String? userId,
  ) {
    final cardColor = isDark
        ? Color.lerp(goal.color, colorScheme.surfaceContainerHigh, 0.45)!
        : goal.color;
""",
         """  Widget _buildGoalCard(
    CheckInGoal goal,
    ColorScheme colorScheme,
    String? userId,
  ) {
    // 深色下的压暗规则收敛在 AppSemanticColorAdaptation 里
    final cardColor = context.adaptSemanticColor(goal.color);
"""),
        ("      borderRadius: BorderRadius.circular(12),\n",
         "      borderRadius: AppRadius.controlAll,\n"),
        ("          borderRadius: BorderRadius.circular(12),\n",
         "          borderRadius: AppRadius.controlAll,\n"),
        ("                borderRadius: BorderRadius.circular(10),\n",
         "                borderRadius: AppRadius.controlAll,\n"),
        ("        borderRadius: BorderRadius.circular(16),\n",
         "        borderRadius: AppRadius.cardAll,\n"),
        ("                        borderRadius: BorderRadius.circular(4),\n",
         "                        borderRadius: AppRadius.gridAll,\n"),
        ("                              borderRadius: BorderRadius.circular(20)),\n",
         "                              borderRadius: AppRadius.sheetAll),\n"),
        ("        borderRadius: BorderRadius.circular(20),\n",
         "        borderRadius: AppRadius.sheetAll,\n"),
    ],
    "lib/widgets/date_picker_panel.dart": [
        ("""import 'package:flutter/material.dart';

/// 顶部展开的日期选择器，支持月历网格与跨年月份滑动切换。
""",
         """import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 顶部展开的日期选择器，支持月历网格与跨年月份滑动切换。
"""),
        ("""  static const int totalMonths = (endYear - startYear + 1) * 12;
  static const Color themeGreen = Color(0xFFADD896);
""",
         """  static const int totalMonths = (endYear - startYear + 1) * 12;
"""),
        ("""    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelBg = isDark ? const Color(0xFF2D3A2E) : DatePickerPanel.themeGreen;
    final selectedDayColor = isDark ? const Color(0xFF6B7B6C) : Colors.white;
    final todayColor = isDark ? const Color(0xFF6B8F5A) : const Color(0xFF8AAF6A);
    final textColor = isDark ? Colors.white70 : Colors.black87;
    final textColorSecondary = isDark ? Colors.white54 : Colors.black54;
    final monthActiveBg = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.12);
    final monthBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.25)
        : Colors.black.withValues(alpha: 0.25);

    return Material(
      color: panelBg,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: _weekdays
                  .map((d) => SizedBox(
                        width: 36,
                        child: Text(
                          d,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: textColorSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 8),
            GestureDetector(
""",
         """    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final textColor = colorScheme.onSurface;
    final textColorSecondary = colorScheme.onSurfaceVariant;

    return Material(
      color: surfaces.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.panelBottom,
        side: BorderSide(color: surfaces.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: _weekdays
                  .map((d) => SizedBox(
                        width: 36,
                        child: Text(
                          d,
                          textAlign: TextAlign.center,
                          style: AppText.caption.copyWith(
                            color: textColorSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: AppSpacing.sm),
            GestureDetector(
"""),
        ("""                  final isCurrent = _isSameDay(date, currentDate);
                  final isToday = _isSameDay(date, _today);

                  Color? bgColor;
                  Color cellTextColor = textColor;
                  if (isCurrent) {
                    bgColor = selectedDayColor;
                  } else if (isToday) {
                    bgColor = todayColor;
                  }

                  return GestureDetector(
                    onTap: () => _selectDay(day),
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: bgColor,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '$day',
                          style: TextStyle(
                            color: cellTextColor,
                            fontSize: 15,
                            fontWeight:
                                isCurrent ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
""",
         """                  final isCurrent = _isSameDay(date, currentDate);
                  final isToday = _isSameDay(date, _today);

                  // 选中：主色实心填充；今天：主色细边框（不填充，避免和选中撞色）
                  final Color? bgColor = isCurrent ? colorScheme.primary : null;
                  final Border? border = !isCurrent && isToday
                      ? Border.all(color: colorScheme.primary)
                      : null;
                  final cellTextColor =
                      isCurrent ? colorScheme.onPrimary : textColor;

                  return GestureDetector(
                    onTap: () => _selectDay(day),
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: bgColor,
                          border: border,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '$day',
                          style: TextStyle(
                            color: cellTextColor,
                            fontSize: 15,
                            fontWeight:
                                isCurrent ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
"""),
        ("""            const SizedBox(height: 16),
            SizedBox(
              height: 40,
""",
         """            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              height: AppSizes.iconButton,
"""),
        ("""                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: _yearItemWidth,
                        child: Center(
                          child: Text(
                            '${item.year}',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    );
""",
         """                    return Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: SizedBox(
                        width: _yearItemWidth,
                        child: Center(
                          child: Text(
                            '${item.year}',
                            style: AppText.body.copyWith(
                              color: textColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    );
"""),
        ("""                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => _selectMonth(item.monthGlobalIndex!),
                      child: Container(
                        width: _monthItemWidth,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: isActive
                              ? monthActiveBg
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isActive
                                ? Colors.transparent
                                : monthBorderColor,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${item.month}月',
                          style: TextStyle(
                            color: textColor,
                            fontSize: 14,
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
""",
         """                  return Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: GestureDetector(
                      onTap: () => _selectMonth(item.monthGlobalIndex!),
                      child: Container(
                        width: _monthItemWidth,
                        padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: isActive
                              ? colorScheme.primaryContainer
                              : Colors.transparent,
                          borderRadius: AppRadius.sheetAll,
                          border: Border.all(
                            color: isActive
                                ? Colors.transparent
                                : surfaces.border,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${item.month}月',
                          style: AppText.body.copyWith(
                            color: isActive
                                ? colorScheme.onPrimaryContainer
                                : textColor,
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
"""),
        ("""            if (!_isCurrentMonth) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: _goToToday,
                  icon: Icon(Icons.today, size: 16, color: textColor),
                  label: Text(
                    '返回今天',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    backgroundColor: isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.05),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
""",
         """            if (!_isCurrentMonth) ...[
              const SizedBox(height: AppSpacing.sm),
              Center(
                child: TextButton.icon(
                  onPressed: _goToToday,
                  icon: const Icon(Icons.today, size: 16),
                  label: const Text('返回今天'),
                ),
              ),
            ],
"""),
    ],
}
