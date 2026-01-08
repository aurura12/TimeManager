import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../widgets/time_grid_tile.dart';
import '../models/category.dart'; // 请确保你创建了这个模型

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // 记录当前拖动选中的索引集合
  final Set<int> _tempSelectedIndices = {};
  final GlobalKey _gridKey = GlobalKey();

  // 模拟分类数据（实际开发建议放进 Provider）
  final List<Category> categories = [
    Category(
        name: '学习',
        color: const Color(0xFFD4AF37),
        subCategories: ['阅读', '编程']),
    Category(
        name: '工作',
        color: const Color(0xFF9CB86A),
        subCategories: ['会议', '文档']),
    Category(name: '运动', color: const Color(0xFF4A90E2)),
  ];

  // 计算手势滑过的格子索引
  void _handlePanUpdate(DragUpdateDetails details) {
    final RenderBox box =
        _gridKey.currentContext!.findRenderObject() as RenderBox;
    final Offset localOffset = box.globalToLocal(details.globalPosition);

    // 这里的 45 是行高，gridWidth/6 是格子宽
    double gridWidth = box.size.width;
    int row = (localOffset.dy / 47).floor(); // 45行高 + 2间距
    int col = (localOffset.dx / (gridWidth / 6)).floor();

    if (row >= 0 && row < 24 && col >= 0 && col < 6) {
      int index = row * 6 + col;
      setState(() {
        _tempSelectedIndices.add(index);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeProvider = Provider.of<TimeProvider>(context);
    final selectedDate = timeProvider.currentDate;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF9CB86A),
        title: _buildAppBarTitle(timeProvider, selectedDate),
      ),
      body: Row(
        children: [
          // 1. 左侧时间轴 (固定宽度)
          _buildLeftTimeAxis(),

          // 2. 中间网格 (支持滑动多选)
          Expanded(
            child: GestureDetector(
              onPanStart: (_) => setState(() => _tempSelectedIndices.clear()),
              onPanUpdate: _handlePanUpdate,
              child: ListView.builder(
                key: _gridKey,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: 24,
                itemBuilder: (context, h) => _buildGridRow(h, timeProvider),
              ),
            ),
          ),

          // 3. 右侧分类面板
          _buildCategorySidebar(timeProvider),
        ],
      ),
    );
  }

  // 构建每一行网格
  Widget _buildGridRow(int h, TimeProvider provider) {
    return Container(
      height: 45,
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: List.generate(6, (m) {
          int index = h * 6 + m;
          bool isTempSelected = _tempSelectedIndices.contains(index);
          return Expanded(
            child: Container(
              margin: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                // 如果在拖动中，显示高亮色，否则显示 Provider 里的颜色
                color: isTempSelected
                    ? Colors.blue.withOpacity(0.5)
                    : (provider.slots[index].color ?? Colors.grey[200]),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Center(
                child: Text(
                  provider.slots[index].label ?? "",
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // 左侧时间轴
  Widget _buildLeftTimeAxis() {
    return SizedBox(
      width: 50,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: 24,
        itemBuilder: (context, h) => Container(
          height: 45,
          alignment: Alignment.center,
          child: Text("$h:00",
              style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        ),
      ),
    );
  }

  // 右侧分类侧边栏
  Widget _buildCategorySidebar(TimeProvider provider) {
    return Container(
      width: 80,
      color: Colors.grey[100],
      child: ListView(
        children:
            categories.map((cat) => _buildCategoryItem(cat, provider)).toList(),
      ),
    );
  }

  Widget _buildCategoryItem(Category cat, TimeProvider provider) {
    return InkWell(
      onTap: () {
        if (_tempSelectedIndices.isNotEmpty) {
          // 批量给选中的格子分配分类
          provider.assignCategoryToSlots(_tempSelectedIndices, cat);
          setState(() => _tempSelectedIndices.clear());
        }
      },
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
            color: cat.color, borderRadius: BorderRadius.circular(8)),
        child: Text(cat.name,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  // 复用你之前的 AppBar Title 代码...
  Widget _buildAppBarTitle(TimeProvider provider, DateTime date) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 18),
          onPressed: () => provider.previousDay(),
        ),
        Text("${date.month}月${date.day}日"),
        IconButton(
          icon: const Icon(Icons.arrow_forward_ios, size: 18),
          onPressed: () => provider.nextDay(),
        ),
      ],
    );
  }
}
