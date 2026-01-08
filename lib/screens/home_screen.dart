import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/category.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey _gridKey = GlobalKey();
  // 使用初始化好的控制器，解决 late 初始化可能导致的 Bug
  final ScrollController _scrollController = ScrollController();

  int? _dragStartIndex;
  int? _dragEndIndex;

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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // 精准计算索引：触点位置 + 滚动偏移
  int _calculateIndex(Offset globalPosition) {
    final RenderBox? box =
        _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return 0;

    final Offset localOffset = box.globalToLocal(globalPosition);
    double adjustedDy = localOffset.dy + _scrollController.offset;

    // 47 = 45(高度) + 2(上下边距总和)
    int row = (adjustedDy / 47).floor().clamp(0, 23);
    int col = (localOffset.dx / (box.size.width / 6)).floor().clamp(0, 5);

    return row * 6 + col;
  }

  bool _isHighlighted(int index) {
    if (_dragStartIndex == null || _dragEndIndex == null) return false;
    int s =
        _dragStartIndex! < _dragEndIndex! ? _dragStartIndex! : _dragEndIndex!;
    int e =
        _dragStartIndex! < _dragEndIndex! ? _dragEndIndex! : _dragStartIndex!;
    return index >= s && index <= e;
  }

  @override
  Widget build(BuildContext context) {
    final timeProvider = Provider.of<TimeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF9CB86A),
        title: _buildAppBarTitle(timeProvider, timeProvider.currentDate),
      ),
      body: Row(
        children: [
          // 中间主内容区
          Expanded(
            child: GestureDetector(
              onPanStart: (d) => setState(() {
                _dragStartIndex = _calculateIndex(d.globalPosition);
                _dragEndIndex = _dragStartIndex;
              }),
              onPanUpdate: (d) => setState(() {
                _dragEndIndex = _calculateIndex(d.globalPosition);
              }),
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: 24,
                itemBuilder: (context, h) =>
                    _buildIntegratedRow(h, timeProvider),
              ),
            ),
          ),
          // 右侧侧边栏
          _buildCategorySidebar(timeProvider),
        ],
      ),
    );
  }

  // 将时间轴和网格集成在一行，解决滑动和对齐问题
  Widget _buildIntegratedRow(int h, TimeProvider provider) {
    return Row(
      children: [
        // 左侧时间轴文字
        Container(
          width: 55,
          height: 45,
          alignment: Alignment.center,
          child: Text(
            "${h.toString().padLeft(2, '0')}:00",
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
        ),
        // 右侧网格
        Expanded(
          child: Container(
            key: h == 0 ? _gridKey : null, // 只在第一行挂载 Key 用于计算宽度
            child: _buildGridRow(h, provider),
          ),
        ),
      ],
    );
  }

  Widget _buildGridRow(int h, TimeProvider provider) {
    return Container(
      height: 45,
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: () {
          List<Widget> segments = [];
          int m = 0;
          while (m < 6) {
            int index = h * 6 + m;
            var slot = provider.slots[index];
            String? label = slot.label;

            if (label != null && slot.color != null) {
              int span = 1;
              while (m + span < 6 &&
                  provider.slots[h * 6 + m + span].label == label) {
                span++;
              }
              bool highlighted = false;
              for (int k = 0; k < span; k++) {
                if (_isHighlighted(h * 6 + m + k)) {
                  highlighted = true;
                  break;
                }
              }

              segments.add(Expanded(
                flex: span,
                child: Container(
                  margin: EdgeInsets.only(
                    top: 1,
                    bottom: 1,
                    left: _shouldBridgeLeft(provider, index) ? 0 : 1,
                    right:
                        _shouldBridgeRight(provider, index + span - 1) ? 0 : 1,
                  ),
                  decoration: BoxDecoration(
                    color: highlighted
                        ? Colors.blue.withValues(alpha: 0.3)
                        : slot.color!,
                    borderRadius: _computeSegmentBorderRadius(
                        provider, h, m, span, highlighted),
                  ),
                  child: Center(
                    child: Text(label,
                        style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                            fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
              ));
              m += span;
            } else {
              bool highlighted = _isHighlighted(index);
              segments.add(Expanded(
                flex: 1,
                child: Container(
                  margin: const EdgeInsets.all(1),
                  decoration: BoxDecoration(
                    color: highlighted
                        ? Colors.blue.withValues(alpha: 0.3)
                        : const Color.fromARGB(255, 188, 186, 186), // 深灰色
                    borderRadius: BorderRadius.circular(4),
                  ),
                  // 关键改动：去掉 SizedBox.shrink()，或者使用 BoxConstraints.expand()
                  child: const SizedBox.expand(),
                ),
              ));
              m++;
            }
          }
          return segments;
        }(),
      ),
    );
  }

  // --- 逻辑辅助函数 ---
  bool _shouldBridgeLeft(TimeProvider p, int i) =>
      i % 6 != 0 &&
      p.slots[i].label != null &&
      p.slots[i].label == p.slots[i - 1].label;
  bool _shouldBridgeRight(TimeProvider p, int i) =>
      i % 6 != 5 &&
      p.slots[i].label != null &&
      p.slots[i].label == p.slots[i + 1].label;

  BorderRadius _computeSegmentBorderRadius(
      TimeProvider p, int h, int startM, int span, bool isHighlight) {
    if (isHighlight) return BorderRadius.circular(4);
    int startIndex = h * 6 + startM;
    int endIndex = startIndex + span - 1;
    bool leftRounded = (startIndex % 6 == 0) ||
        (p.slots[startIndex].label != p.slots[startIndex - 1].label);
    bool rightRounded = (endIndex % 6 == 5) ||
        (p.slots[endIndex].label != p.slots[endIndex + 1].label);
    return BorderRadius.only(
      topLeft: leftRounded ? const Radius.circular(4) : Radius.zero,
      bottomLeft: leftRounded ? const Radius.circular(4) : Radius.zero,
      topRight: rightRounded ? const Radius.circular(4) : Radius.zero,
      bottomRight: rightRounded ? const Radius.circular(4) : Radius.zero,
    );
  }

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
        if (_dragStartIndex != null && _dragEndIndex != null) {
          int s = _dragStartIndex! < _dragEndIndex!
              ? _dragStartIndex!
              : _dragEndIndex!;
          int e = _dragStartIndex! < _dragEndIndex!
              ? _dragEndIndex!
              : _dragStartIndex!;
          Set<int> rangeIndices = {};
          for (int i = s; i <= e; i++) rangeIndices.add(i);
          provider.assignCategoryToSlots(rangeIndices, cat);
          setState(() {
            _dragStartIndex = null;
            _dragEndIndex = null;
          });
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

  Widget _buildAppBarTitle(TimeProvider provider, DateTime date) {
    return Row(
      children: [
        IconButton(
            icon: const Icon(Icons.arrow_back_ios, size: 18),
            onPressed: () => provider.previousDay()),
        Text("${date.month}月${date.day}日"),
        IconButton(
            icon: const Icon(Icons.arrow_forward_ios, size: 18),
            onPressed: () => provider.nextDay()),
        const Spacer(),
        IconButton(
            icon: const Icon(Icons.undo), onPressed: () => provider.undo()),
        IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => _showClearDialog(context, provider)),
      ],
    );
  }

  void _showClearDialog(BuildContext context, TimeProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("确认清空"),
        content: const Text("确定清空今天所有记录吗？"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
              onPressed: () {
                provider.clearAll();
                Navigator.pop(context);
              },
              child: const Text("确定")),
        ],
      ),
    );
  }
}
