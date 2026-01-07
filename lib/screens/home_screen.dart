import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../widgets/time_grid_tile.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final timeProvider = Provider.of<TimeProvider>(context);
    final selectedDate = timeProvider.currentDate; // 假设 provider 里有当前日期

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF9CB86A), // 匹配图片的绿色
        elevation: 0,
        // 自定义 title 部分，实现日期切换
        title: Row(
          children: [
            // 日期切换器
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios,
                      size: 20, color: Colors.white),
                  onPressed: () => timeProvider.previousDay(),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text("${selectedDate.month}月${selectedDate.day}日",
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 4),
                        Text(
                            "${selectedDate.year}\n周${_weekdayName(selectedDate.weekday)}",
                            style: const TextStyle(fontSize: 10, height: 1.1)),
                      ],
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios,
                      size: 20, color: Colors.white),
                  onPressed: () => timeProvider.nextDay(),
                ),
              ],
            ),
            const Spacer(),
            // 右侧操作按钮
            IconButton(
              icon: const Icon(Icons.undo, color: Colors.white),
              onPressed: () => timeProvider.undo(),
            ),
            IconButton(
              icon: const Icon(Icons.format_align_left,
                  color: Colors.white), // 类似图片中的图标
              onPressed: () {},
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: 24,
              itemBuilder: (context, h) =>
                  _buildHourRow(context, h, timeProvider),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHourRow(BuildContext context, int h, TimeProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2), // 调整行与行之间的额外缝隙
      child: SizedBox(
        height: 45, // 稍微压缩高度
        child: Row(
          children: [
            // 1. 调窄左侧时间宽度
            SizedBox(
              width: 60, // 从120缩减到60
              child: Center(
                child: Text(
                  "$h:00", // 仿照图片显示区间
                  style: TextStyle(color: Colors.grey[700], fontSize: 16),
                ),
              ),
            ),
            // 2. 时间网格
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.only(right: 8),
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
                  mainAxisSpacing: 1, // 上下间隙
                  crossAxisSpacing: 1, // 左右间隙，保持一致
                  childAspectRatio: 1.2, // 调整格子长宽比
                ),
                itemCount: 6,
                itemBuilder: (context, m) {
                  int index = h * 6 + m;
                  return TimeGridTile(
                    slot: provider.slots[index],
                    onTap: () => provider.toggleSlot(index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _weekdayName(int d) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return names[(d - 1) % 7];
  }
}
