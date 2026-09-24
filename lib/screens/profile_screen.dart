import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/profile_settings_drawer.dart';
import '../widgets/calendar_sync_status_badge.dart';
import '../providers/time_provider.dart';
import '../utils/platform_features.dart';
import 'event_detail_screen.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

enum _DeletedEventDisplayMode { grouped, separate, hidden }

enum _StatisticsFilterAction {
  allEvents,
  parentSummary,
  showDeletedInParent,
  hideDeletedInParent,
  groupDeleted,
  separateDeleted,
  hideDeletedInAll,
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _groupValue = 0; // 0: 列表, 1: 饼图
  int _touchedIndex = -1;
  bool _showParentOnly = false; // false: 全部事件, true: 只显示父事件
  bool _showDeletedEvents = true;
  bool _groupDeletedEvents = true; // 全部事件视图中是否合并已删除标签

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TimeProvider>(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      drawer: ProfileSettingsDrawer(onChanged: () => setState(() {})),
      appBar: AppBar(
        title: Text(
          "个人中心",
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          // 该徽章只反映 Google 日历同步，桌面端本就关闭 Google 同步，不再展示。
          if (!isDesktopPlatform)
            CalendarSyncStatusBadge(
              onNotLoggedIn: () => Scaffold.of(context).openDrawer(),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _buildTrendChart(provider),
          const SizedBox(height: 20),
          _buildCustomTabBar(),
          const SizedBox(height: 20),
          _buildSummaryCards(provider, _tabController.index),
          const SizedBox(height: 20),
          _buildStatisticsHeader(),
          const SizedBox(height: AppSpacing.sm),
          _buildStatisticsFilters(),
          const SizedBox(height: AppSpacing.sm),
          _groupValue == 0
              ? _buildDetailList(provider, _tabController.index)
              : _buildPieChart(provider, _tabController.index),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildStatisticsHeader() {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Expanded(
          child: Text(
            '分类统计',
            style: AppText.sectionTitle.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
        ),
        Semantics(
          label: '统计展示方式',
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment<int>(
                value: 0,
                label: Text('列表'),
                icon: Icon(Icons.table_chart_outlined),
                tooltip: '列表视图',
              ),
              ButtonSegment<int>(
                value: 1,
                label: Text('饼图'),
                icon: Icon(Icons.pie_chart_outline),
                tooltip: '饼图视图',
              ),
            ],
            selected: {_groupValue},
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              if (selection.isEmpty) return;
              setState(() {
                _groupValue = selection.first;
                _touchedIndex = -1;
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatisticsFilters() {
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          _buildEventHierarchyControl(),
          _buildDeletedEventControl(),
        ],
      ),
    );
  }

  Widget _buildEventHierarchyControl() {
    final surfaces = AppSurfaces.of(context);

    return PopupMenuButton<_StatisticsFilterAction>(
      tooltip: '统计层级',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      offset: const Offset(0, AppSpacing.xs),
      constraints: const BoxConstraints(
        minWidth: 260,
        maxWidth: 320,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadius.cardAll,
      ),
      borderRadius: AppRadius.controlAll,
      color: surfaces.card,
      onSelected: _onStatisticsFilterActionSelected,
      itemBuilder: (context) => [
        _buildFilterMenuHeader('统计层级'),
        _buildFilterMenuItem(
          action: _StatisticsFilterAction.allEvents,
          label: '全部事件',
          description: '父事件和子事件分别显示',
          selected: !_showParentOnly,
        ),
        _buildFilterMenuItem(
          action: _StatisticsFilterAction.parentSummary,
          label: '父事件汇总',
          description: '将子事件合并到所属父事件',
          selected: _showParentOnly,
        ),
      ],
      child: _buildStatisticsFilterControl(
        prefix: '层级',
        value: _showParentOnly ? '父事件汇总' : '全部事件',
      ),
    );
  }

  Widget _buildDeletedEventControl() {
    final surfaces = AppSurfaces.of(context);
    final menuItems = <PopupMenuEntry<_StatisticsFilterAction>>[
      _buildFilterMenuHeader('已删除事件'),
      if (_showParentOnly) ...[
        _buildFilterMenuItem(
          action: _StatisticsFilterAction.showDeletedInParent,
          label: '显示',
          description: '计入“已删除”汇总',
          selected: _showDeletedEvents,
        ),
        _buildFilterMenuItem(
          action: _StatisticsFilterAction.hideDeletedInParent,
          label: '不显示',
          description: '从统计结果中排除',
          selected: !_showDeletedEvents,
        ),
      ] else ...[
        _buildFilterMenuItem(
          action: _StatisticsFilterAction.groupDeleted,
          label: '合并显示',
          description: '所有已删除事件合并为“已删除”',
          selected:
              _deletedEventDisplayMode == _DeletedEventDisplayMode.grouped,
        ),
        _buildFilterMenuItem(
          action: _StatisticsFilterAction.separateDeleted,
          label: '独立显示',
          description: '保留原事件名称，分别列出',
          selected:
              _deletedEventDisplayMode == _DeletedEventDisplayMode.separate,
        ),
        _buildFilterMenuItem(
          action: _StatisticsFilterAction.hideDeletedInAll,
          label: '不显示',
          description: '从统计结果中排除',
          selected: _deletedEventDisplayMode == _DeletedEventDisplayMode.hidden,
        ),
      ],
    ];

    return PopupMenuButton<_StatisticsFilterAction>(
      tooltip: '已删除事件',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      offset: const Offset(0, AppSpacing.xs),
      constraints: const BoxConstraints(
        minWidth: 260,
        maxWidth: 320,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadius.cardAll,
      ),
      borderRadius: AppRadius.controlAll,
      color: surfaces.card,
      onSelected: _onStatisticsFilterActionSelected,
      itemBuilder: (context) => menuItems,
      child: _buildStatisticsFilterControl(
        prefix: '删除',
        value: _showParentOnly
            ? (_showDeletedEvents ? '显示' : '不显示')
            : switch (_deletedEventDisplayMode) {
                _DeletedEventDisplayMode.grouped => '合并显示',
                _DeletedEventDisplayMode.separate => '独立显示',
                _DeletedEventDisplayMode.hidden => '不显示',
              },
        compact: true,
      ),
    );
  }

  Widget _buildStatisticsFilterControl({
    required String prefix,
    required String value,
    bool compact = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);

    return Container(
      height: AppSizes.button,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.xs : AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: surfaces.subtle,
        borderRadius: AppRadius.controlAll,
        border: Border.all(color: surfaces.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$prefix：',
                  style: AppText.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: AppText.button.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: AppSpacing.xs),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  _DeletedEventDisplayMode get _deletedEventDisplayMode {
    if (!_showDeletedEvents) return _DeletedEventDisplayMode.hidden;
    return _groupDeletedEvents
        ? _DeletedEventDisplayMode.grouped
        : _DeletedEventDisplayMode.separate;
  }

  PopupMenuItem<_StatisticsFilterAction> _buildFilterMenuHeader(String label) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopupMenuItem<_StatisticsFilterAction>(
      enabled: false,
      height: AppSizes.button,
      child: Text(
        label,
        style: AppText.caption.copyWith(
          color: colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  PopupMenuItem<_StatisticsFilterAction> _buildFilterMenuItem({
    required _StatisticsFilterAction action,
    required String label,
    required String description,
    required bool selected,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopupMenuItem<_StatisticsFilterAction>(
      value: action,
      child: Row(
        children: [
          Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 20,
            color:
                selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.body.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                Text(
                  description,
                  style: AppText.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _onStatisticsFilterActionSelected(_StatisticsFilterAction action) {
    setState(() {
      switch (action) {
        case _StatisticsFilterAction.allEvents:
          _showParentOnly = false;
        case _StatisticsFilterAction.parentSummary:
          _showParentOnly = true;
        case _StatisticsFilterAction.showDeletedInParent:
          _showDeletedEvents = true;
        case _StatisticsFilterAction.hideDeletedInParent:
          _showDeletedEvents = false;
        case _StatisticsFilterAction.groupDeleted:
          _showDeletedEvents = true;
          _groupDeletedEvents = true;
        case _StatisticsFilterAction.separateDeleted:
          _showDeletedEvents = true;
          _groupDeletedEvents = false;
        case _StatisticsFilterAction.hideDeletedInAll:
          _showDeletedEvents = false;
      }
    });
  }

  // 核心：双曲线折线图组件
  Widget _buildTrendChart(TimeProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final daily = _computeDaily30(provider); // 一次遍历，两条曲线共用
    return Container(
      height: 220,
      padding: const EdgeInsets.fromLTRB(10, 20, 20, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: AppRadius.sheetAll,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
          )
        ],
      ),
      child: Column(
        children: [
          Text(
            "最近一月趋势",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 15),
          Expanded(
            child: LineChart(
              LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: FlTitlesData(
                  show: true,
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  // 底部显示中文日期
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: 5,
                      getTitlesWidget: (value, meta) {
                        final now = DateTime.now();
                        final index = value.toInt();
                        final date = now.subtract(Duration(days: 30 - index));
                        return Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text('${date.day}日',
                              style: TextStyle(
                                fontSize: 10,
                                color: colorScheme.onSurfaceVariant,
                              )),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  // 曲线 1: 投入时间 (绿色)
                  LineChartBarData(
                    spots: _generateTimeSpots(daily), // 真实数据点
                    isCurved: true,
                    color: AppSemanticColors.brand,
                    barWidth: 3,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                        show: true,
                        color: AppSemanticColors.brand.withValues(alpha: 0.1)),
                  ),
                  // 曲线 2: 事件数量 (橙色)
                  LineChartBarData(
                    spots: _generateCountSpots(daily), // 真实数据点
                    isCurved: true,
                    color: AppSemanticColors.warning,
                    barWidth: 3,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                        show: true,
                        color:
                            AppSemanticColors.warning.withValues(alpha: 0.05)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // 图例
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegend(AppSemanticColors.brand, "投入时长(h)"),
              const SizedBox(width: 20),
              _buildLegend(AppSemanticColors.warning, "事件数量"),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildLegend(Color color, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(fontSize: 10, color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  // 自定义 TabBar 样式
  Widget _buildCustomTabBar() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 45,
      // 如果 TabBar 放在过窄的容器里，可以尝试稍微调大外层宽度或减小 padding
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.cardAll,
      ),
      child: TabBar(
        controller: _tabController,
        // 1. 关闭滚动，确保 TabBar 整体填满 Container，滑块在内部滑动
        isScrollable: false,

        // 2. 将指示器设置为 tab，这样白色块会填满整个选项区域，滑动感更强
        indicatorSize: TabBarIndicatorSize.tab,

        // 3. 移除默认的底部横线
        dividerColor: Colors.transparent,

        indicator: BoxDecoration(
          color: colorScheme.surfaceContainerLowest,
          borderRadius: AppRadius.controlAll,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 5,
            )
          ],
        ),
        // 品牌绿直接当文字色在白底只有约 2.2:1、在 surfaceContainerHigh 上更低。
        // 这里按"选中块所在的更差底面"取可读版本，保持色相但压到 ≥4.5:1。
        labelColor: AppSemanticColors.readableOn(
            AppSemanticColors.brand, colorScheme.surfaceContainerHigh),
        unselectedLabelColor: colorScheme.onSurfaceVariant,
        labelStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          height: 1.1, // 微调行高，防止文字偏下
        ),

        // 4. 关键：将 labelPadding 设为极小值，给文字留出最大空间
        labelPadding: const EdgeInsets.symmetric(horizontal: 2),

        tabs: const [
          Tab(child: Center(child: Text("今天", maxLines: 1))),
          Tab(child: Center(child: Text("最近一周", maxLines: 1))),
          Tab(child: Center(child: Text("最近一月", maxLines: 1))),
          Tab(child: Center(child: Text("总览", maxLines: 1))),
        ],
        onTap: (index) => setState(() {}),
      ),
    );
  }

  // 概览卡片
  Widget _buildSummaryCards(TimeProvider provider, int tabIndex) {
    final stats = _getDataByTab(provider, tabIndex);
    double totalHours = stats.values.fold(0, (sum, item) => sum + item);

    return Row(
      children: [
        _statCard(
            "总投入/小时", totalHours.toStringAsFixed(1), AppSemanticColors.brand),
        const SizedBox(width: 16),
        _statCard("涉及项目数", stats.length.toString(), AppSemanticColors.info),
      ],
    );
  }

  Widget _statCard(String label, String value, Color color) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLowest,
          borderRadius: AppRadius.sheetAll,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -1)),
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 详细列表
  Widget _buildDetailList(TimeProvider provider, int tabIndex) {
    final colorScheme = Theme.of(context).colorScheme;
    final rawStats = _getDataByTab(provider, tabIndex);
    // 将 Map 转换为 List 并按时长(value)降序排序
    final stats = rawStats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    double total = stats.fold(0, (sum, item) => sum + item.value);

    if (stats.isEmpty) {
      return Center(
          child: Text("本时段暂无记录",
              style: TextStyle(color: colorScheme.onSurfaceVariant)));
    }

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: AppRadius.sheetAll,
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: stats.length,
        separatorBuilder: (context, index) =>
            Divider(height: 1, color: colorScheme.outlineVariant),
        itemBuilder: (context, index) {
          final entry = stats[index];
          String key = entry.key;
          double val = entry.value;
          double percent = (val / total) * 100;
          Color itemColor = AppSemanticColors.chartAt(index);

          return Material(
            color: Colors.transparent,
            child: ListTile(
              dense: true,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => EventDetailScreen(
                      eventName: key,
                      tabIndex: tabIndex,
                    ),
                  ),
                );
              },
              leading: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                    color: itemColor.withValues(alpha: 0.6),
                    shape: BoxShape.circle),
              ),
              title: Text(key,
                  style: TextStyle(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
              subtitle: Text("占比 ${percent.toStringAsFixed(1)}%",
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  )),
              trailing: Text("${val.toStringAsFixed(2)} h",
                  style: TextStyle(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                      fontSize: 16)),
            ),
          );
        },
      ),
    );
  }

  // 饼状图统计
  Widget _buildPieChart(TimeProvider provider, int tabIndex) {
    final colorScheme = Theme.of(context).colorScheme;
    final rawStats = _getDataByTab(provider, tabIndex);
    final stats = rawStats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    double total = stats.fold(0, (sum, item) => sum + item.value);

    if (stats.isEmpty) {
      return Center(
          child: Text("本时段暂无记录",
              style: TextStyle(color: colorScheme.onSurfaceVariant)));
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: AppRadius.sheetAll,
      ),
      child: Column(
        children: [
          SizedBox(
            height: 260,
            child: PieChart(
              PieChartData(
                pieTouchData: PieTouchData(
                  touchCallback: (FlTouchEvent event, pieTouchResponse) {
                    final touchedSection = pieTouchResponse?.touchedSection;
                    setState(() {
                      if (!event.isInterestedForInteractions ||
                          touchedSection == null) {
                        if (event is FlTapUpEvent) {
                          _touchedIndex = -1;
                        }
                        return;
                      }
                      _touchedIndex = touchedSection.touchedSectionIndex;
                    });

                    if (event is FlTapUpEvent && touchedSection != null) {
                      final index = touchedSection.touchedSectionIndex;
                      if (index >= 0 && index < stats.length) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => EventDetailScreen(
                              eventName: stats[index].key,
                              tabIndex: tabIndex,
                            ),
                          ),
                        );
                      }
                    }
                  },
                ),
                sectionsSpace: 2,
                centerSpaceRadius: 40,
                sections: List.generate(stats.length, (i) {
                  final entry = stats[i];
                  final color = AppSemanticColors.chartAt(i);
                  final percentage = (entry.value / total * 100);
                  final isTouched = i == _touchedIndex;
                  final double fontSize = isTouched ? 14.0 : 12.0;
                  final double radius = isTouched ? 60.0 : 50.0;

                  return PieChartSectionData(
                    color: color,
                    value: entry.value,
                    title: isTouched
                        ? '${entry.key}\n${percentage.toStringAsFixed(1)}%'
                        : (percentage < 5
                            ? ''
                            : '${percentage.toStringAsFixed(1)}%'),
                    radius: radius,
                    titlePositionPercentageOffset: isTouched ? 1.5 : 0.5,
                    titleStyle: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                        color: isTouched
                            ? colorScheme.onSurface
                            : AppSemanticColors.onColor(color)),
                  );
                }),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 图例
          Wrap(
            spacing: 16,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: List.generate(stats.length, (i) {
              final entry = stats[i];
              final color = AppSemanticColors.chartAt(i);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  Text(entry.key,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      )),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }

  // 获取数据方法保持不变
  Map<String, double> _getDataByTab(TimeProvider provider, int index) {
    DateTime now = DateTime.now();
    DateTime start;
    if (index == 0) {
      start = DateTime(now.year, now.month, now.day);
    } else if (index == 1) {
      start = now.subtract(const Duration(days: 7));
    } else if (index == 2) {
      // 近一月：取上个月的同一天；若该日不存在（如 3/31 → 2 月只有 28/29 天），
      // 取上个月最后一天，避免 DateTime 归一化导致窗口错位
      final lastMonthLastDay = DateTime(now.year, now.month, 0);
      start = now.day <= lastMonthLastDay.day
          ? DateTime(now.year, now.month - 1, now.day)
          : lastMonthLastDay;
    } else {
      start = DateTime(2025);
    }
    return _showParentOnly
        ? provider.getParentStatistics(
            start,
            now,
            includeDeleted: _showDeletedEvents,
          )
        : provider.getStatisticsWithTemporaryGrouped(
            start,
            now,
            groupDeleted: _groupDeletedEvents,
            includeDeleted: _showDeletedEvents,
          );
  }

  // 一次遍历最近 30 天，同时得到每日总时长与事件数，
  // 避免时间/数量两个方法各重复遍历一次
  List<({double hours, int count})> _computeDaily30(TimeProvider provider) {
    final now = DateTime.now();
    final daily = <({double hours, int count})>[];
    for (int i = 0; i < 30; i++) {
      final date = now.subtract(Duration(days: 29 - i));
      final dayStats = provider.getStatistics(date, date);
      final hours = double.parse(
        dayStats.values.fold(0.0, (sum, item) => sum + item).toStringAsFixed(1),
      );
      daily.add((hours: hours, count: dayStats.length));
    }
    return daily;
  }

  // 获取最近30天每天的 [时长] 数据点
  List<FlSpot> _generateTimeSpots(List<({double hours, int count})> daily) {
    return List.generate(30, (i) => FlSpot(i + 1.0, daily[i].hours));
  }

  // 获取最近30天每天的 [事件数量] 数据点
  List<FlSpot> _generateCountSpots(List<({double hours, int count})> daily) {
    return List.generate(30, (i) => FlSpot(i + 1.0, daily[i].count.toDouble()));
  }
}
