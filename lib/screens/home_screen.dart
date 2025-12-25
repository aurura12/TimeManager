import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../widgets/time_grid_tile.dart';
import 'statistics_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final timeProvider = Provider.of<TimeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("时间块管理"),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => StatisticsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => _showExportDialog(context, timeProvider.exportData()),
          ),
        ],
      ),
      body: Column(
        children: [
          // 24小时滚动列表
          Expanded(
            child: ListView.builder(
              itemCount: 24,
              itemBuilder: (context, h) => _buildHourRow(context, h, timeProvider),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHourRow(BuildContext context, int h, TimeProvider provider) {
    return Container(
      height: 60,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey[200]!))),
      child: Row(
        children: [
          SizedBox(width: 50, child: Center(child: Text("${h.toString().padLeft(2, '0')}:00"))),
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6),
              itemCount: 6,
              itemBuilder: (context, m) {
                int index = h * 6 + m;
                return TimeGridTile(
                  slot: provider.slots[index],
                  onTap: () => provider.togglePriority(index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showExportDialog(BuildContext context, String data) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("导出成功"),
        content: SelectableText(data),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("关闭"))],
      ),
    );
  }
}