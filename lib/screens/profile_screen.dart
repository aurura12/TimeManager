import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/profile_settings_drawer.dart';
import '../widgets/calendar_sync_status_badge.dart';
import '../providers/time_provider.dart';
import 'event_detail_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TimeProvider>(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      drawer: ProfileSettingsDrawer(onChanged: () => setState(() {})),
      appBar: AppBar(
        title: const Text("个人中心",
            style:
                TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
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

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("分类统计",
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              CupertinoSegmentedControl<int>(
                groupValue: _groupValue,
                borderColor: const Color(0xFF9CB86A),
                selectedColor: const Color(0xFF9CB86A),
                pressedColor: const Color(0xFF9CB86A).withValues(alpha: 0.2),
                children: const {
                  0: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Icon(Icons.table_chart_outlined, size: 20),
                  ),
                  1: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Icon(Icons.pie_chart_outline, size: 20),
                  ),
                },
                onValueChanged: (value) => setState(() => _groupValue = value),
              ),
            ],
          ),
          const SizedBox(height: 12),

          _groupValue == 0
              ? _buildDetailList(provider, _tabController.index)
              : _buildPieChart(provider, _tabController.index),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  // 核心：双曲线折线图组件
  Widget _buildTrendChart(TimeProvider provider) {
    return Container(
      height: 220,
      padding: const EdgeInsets.fromLTRB(10, 20, 20, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(25),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10)
        ],
      ),
      child: Column(
        children: [
          const Text("最近一月趋势",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.grey)),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  // 曲线 1: 投入时间 (绿色)
                  LineChartBarData(
                    spots: _generateTimeSpots(provider), // 真实数据点
                    isCurved: true,
                    color: const Color(0xFF9CB86A),
                    barWidth: 3,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                        show: true,
                        color: const Color(0xFF9CB86A).withValues(alpha: 0.1)),
                  ),
                  // 曲线 2: 事件数量 (橙色)
                  LineChartBarData(
                    spots: _generateCountSpots(provider), // 真实数据点
                    isCurved: true,
                    color: Colors.orangeAccent,
                    barWidth: 3,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                        show: true,
                        color: Colors.orangeAccent.withValues(alpha: 0.05)),
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
              _buildLegend(const Color(0xFF9CB86A), "投入时长(h)"),
              const SizedBox(width: 20),
              _buildLegend(Colors.orangeAccent, "事件数量"),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildLegend(Color color, String text) {
    return Row(
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  // 自定义 TabBar 样式
  Widget _buildCustomTabBar() {
    return Container(
      height: 45,
      // 如果 TabBar 放在过窄的容器里，可以尝试稍微调大外层宽度或减小 padding
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(15),
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
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 5,
            )
          ],
        ),
        labelColor: const Color(0xFF9CB86A),
        unselectedLabelColor: Colors.grey[600],
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
            "总投入/小时", totalHours.toStringAsFixed(1), const Color(0xFF9CB86A)),
        const SizedBox(width: 16),
        _statCard("涉及项目数", stats.length.toString(), const Color(0xFF4A90E2)),
      ],
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(25),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: const TextStyle(
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
                        color: Colors.grey[500],
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
    final rawStats = _getDataByTab(provider, tabIndex);
    // 将 Map 转换为 List 并按时长(value)降序排序
    final stats = rawStats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    double total = stats.fold(0, (sum, item) => sum + item.value);

    if (stats.isEmpty) {
      return Center(
          child: Text("本时段暂无记录", style: TextStyle(color: Colors.grey[400])));
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(25),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: stats.length,
        separatorBuilder: (context, index) =>
            Divider(height: 1, color: Colors.grey[50]),
        itemBuilder: (context, index) {
          final entry = stats[index];
          String key = entry.key;
          double val = entry.value;
          double percent = (val / total) * 100;
          Color itemColor = Colors.primaries[index % Colors.primaries.length];

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
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              subtitle: Text("占比 ${percent.toStringAsFixed(1)}%",
                  style: TextStyle(color: Colors.grey[400], fontSize: 12)),
              trailing: Text("${val.toStringAsFixed(2)} h",
                  style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      color: Color(0xFF2D3436))),
            ),
          );
        },
      ),
    );
  }

  // 饼状图统计
  Widget _buildPieChart(TimeProvider provider, int tabIndex) {
    final rawStats = _getDataByTab(provider, tabIndex);
    final stats = rawStats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    double total = stats.fold(0, (sum, item) => sum + item.value);

    if (stats.isEmpty) {
      return Center(
          child: Text("本时段暂无记录", style: TextStyle(color: Colors.grey[400])));
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(25),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 260,
            child: PieChart(
              PieChartData(
                pieTouchData: PieTouchData(
                  touchCallback: (FlTouchEvent event, pieTouchResponse) {
                    setState(() {
                      if (!event.isInterestedForInteractions ||
                          pieTouchResponse == null ||
                          pieTouchResponse.touchedSection == null) {
                        if (event is FlTapUpEvent) {
                          _touchedIndex = -1;
                        }
                        return;
                      }
                      _touchedIndex =
                          pieTouchResponse.touchedSection!.touchedSectionIndex;
                    });
                  },
                ),
                sectionsSpace: 2,
                centerSpaceRadius: 40,
                sections: List.generate(stats.length, (i) {
                  final entry = stats[i];
                  final color = Colors.primaries[i % Colors.primaries.length];
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
                        color: isTouched ? Colors.black87 : Colors.white),
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
              final color = Colors.primaries[i % Colors.primaries.length];
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
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
      start = DateTime(now.year, now.month - 1, now.day);
    } else {
      start = DateTime(2025);
    }
    return provider.getStatistics(start, now);
  }

  // 获取最近30天每天的 [时长] 数据点
  List<FlSpot> _generateTimeSpots(TimeProvider provider) {
    List<FlSpot> spots = [];
    DateTime now = DateTime.now();
    for (int i = 0; i < 30; i++) {
      DateTime date = now.subtract(Duration(days: 29 - i));
      var dayStats = provider.getStatistics(date, date);
      double totalHours = dayStats.values.fold(0.0, (sum, item) => sum + item);
      totalHours = double.parse(totalHours.toStringAsFixed(1));
      spots.add(FlSpot(i + 1.0, totalHours));
    }
    return spots;
  }

  // 获取最近30天每天的 [事件数量] 数据点
  List<FlSpot> _generateCountSpots(TimeProvider provider) {
    List<FlSpot> spots = [];
    DateTime now = DateTime.now();
    for (int i = 0; i < 30; i++) {
      DateTime date = now.subtract(Duration(days: 29 - i));
      var dayStats = provider.getStatistics(date, date);
      spots.add(FlSpot(i + 1.0, dayStats.length.toDouble()));
    }
    return spots;
  }
}
