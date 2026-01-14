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

  // 管理分类的展开状态
  final Map<int, bool> _expandedCategories = {};

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
    // 注意：这里的 adjustedDy 需要根据整个滚动视图的偏移来计算
    double adjustedDy = localOffset.dy + _scrollController.offset;

    double topPadding = 8.0;
    int row = ((adjustedDy - topPadding) / 45).floor().clamp(0, 23);

    double gridWidth = box.size.width;
    int col =
        ((localOffset.dx - 55) / ((gridWidth - 55) / 6)).floor().clamp(0, 5);

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

  void _handleSelect(Offset globalPosition,
      {bool isClick = false, bool isStart = false}) {
    int currentIndex = _calculateIndex(globalPosition);

    setState(() {
      if (isClick) {
        // --- 逻辑修复：点击切换 ---
        // 如果当前已经选中了东西，且点击的是选中的范围，则清空
        if (_dragStartIndex == currentIndex && _dragEndIndex == currentIndex) {
          _dragStartIndex = null;
          _dragEndIndex = null;
        } else {
          // 否则，单选当前格子
          _dragStartIndex = currentIndex;
          _dragEndIndex = currentIndex;
        }
      } else {
        // --- 逻辑修复：滑动逻辑 ---
        if (isStart) {
          // 每次重新开始滑动时，重置起始点和终点为当前点
          _dragStartIndex = currentIndex;
        }
        _dragEndIndex = currentIndex;
      }
    });
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
          Expanded(
            child: ListView.builder(
              key: _gridKey,
              controller: _scrollController,
              // 如果你想让网格区域完全不响应滚动手势，只响应选中手势：
              // physics: const ClampingScrollPhysics(), // 或者默认
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: 24,
              itemBuilder: (context, h) => _buildIntegratedRow(h, timeProvider),
            ),
          ),
          _buildCategorySidebar(timeProvider),
        ],
      ),
    );
  }

  Widget _buildIntegratedRow(int h, TimeProvider provider) {
    return Row(
      children: [
        // 左侧时间轴：保留默认行为，可以触发 ListView 滚动
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
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 关键：点击事件
            onTapDown: (d) => _handleSelect(d.globalPosition, isClick: true),
            // 关键：滑动开始时，传入 isStart: true 来重置索引
            onPanStart: (d) => _handleSelect(d.globalPosition, isStart: true),
            onPanUpdate: (d) => _handleSelect(d.globalPosition),
            child: Container(
              child: _buildGridRow(h, provider),
            ),
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
      width: 90,
      color: Colors.grey[100],
      child: ListView.builder(
        itemCount: provider.categories.length + 1,
        itemBuilder: (context, index) {
          if (index == provider.categories.length) {
            // 最后一个是添加按钮
            return Padding(
              padding: const EdgeInsets.all(8.0),
              child: ElevatedButton.icon(
                onPressed: () => _showAddCategoryDialog(context, provider),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加', style: TextStyle(fontSize: 12)),
              ),
            );
          }
          return _buildCategoryItem(
              index, provider.categories[index], provider);
        },
      ),
    );
  }

  Widget _buildCategoryItem(int catIndex, Category cat, TimeProvider provider) {
    bool isExpanded = _expandedCategories[catIndex] ?? true;

    return Column(
      children: [
        // 事件项
        InkWell(
          onTap: () => _assignCategory(cat, provider),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            decoration: BoxDecoration(
              color: cat.color,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                // 展开按钮
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _expandedCategories[catIndex] = !isExpanded;
                    });
                  },
                  child: Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
                // 事件名称
                Expanded(
                  child: Text(
                    cat.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 展开后显示子事件
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 8.0, right: 4.0),
            child: Column(
              children: [
                ...cat.subCategories.asMap().entries.map((entry) {
                  int subIndex = entry.key;
                  String subCat = entry.value;
                  return InkWell(
                    onTap: () => _assignSubCategory(cat, subCat, provider),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      decoration: BoxDecoration(
                        color: cat.color.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: Colors.white,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              subCat,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => _removeSubCategory(
                                catIndex, subIndex, provider),
                            child: const Icon(Icons.close,
                                color: Colors.white, size: 12),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                // 添加子事件按钮 - 显示在子事件列表的最后
                GestureDetector(
                  onTap: () => _showAddSubCategoryDialog(
                      context, catIndex, cat, provider),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    decoration: BoxDecoration(
                      color: cat.color.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.white,
                        width: 1,
                      ),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text(
                          '添加',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _assignCategory(Category cat, TimeProvider provider) {
    if (_dragStartIndex != null && _dragEndIndex != null) {
      int s =
          _dragStartIndex! < _dragEndIndex! ? _dragStartIndex! : _dragEndIndex!;
      int e =
          _dragStartIndex! < _dragEndIndex! ? _dragEndIndex! : _dragStartIndex!;
      Set<int> rangeIndices = {};
      for (int i = s; i <= e; i++) {
        rangeIndices.add(i);
      }
      provider.assignCategoryToSlots(rangeIndices, cat);
      setState(() {
        _dragStartIndex = null;
        _dragEndIndex = null;
      });
    }
  }

  void _assignSubCategory(Category cat, String subCat, TimeProvider provider) {
    if (_dragStartIndex != null && _dragEndIndex != null) {
      int s =
          _dragStartIndex! < _dragEndIndex! ? _dragStartIndex! : _dragEndIndex!;
      int e =
          _dragStartIndex! < _dragEndIndex! ? _dragEndIndex! : _dragStartIndex!;
      Set<int> rangeIndices = {};
      for (int i = s; i <= e; i++) {
        rangeIndices.add(i);
      }
      // 创建虚拟类别用于子事件
      Category subCategory = Category(
        name: subCat,
        color: cat.color,
      );
      provider.assignCategoryToSlots(rangeIndices, subCategory);
      setState(() {
        _dragStartIndex = null;
        _dragEndIndex = null;
      });
    }
  }

  void _removeSubCategory(int catIndex, int subIndex, TimeProvider provider) {
    List<String> newSubs =
        List.from(provider.categories[catIndex].subCategories);
    newSubs.removeAt(subIndex);
    Category newCat =
        provider.categories[catIndex].copyWith(subCategories: newSubs);
    provider.updateCategory(catIndex, newCat);
  }

  void _showAddCategoryDialog(BuildContext context, TimeProvider provider) {
    String newCatName = '';
    Color selectedColor = Colors.blue;
    String hexColor = 'FF2196F3';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加事件'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: '事件名称',
                    hintText: '请输入事件名称',
                  ),
                  onChanged: (value) {
                    newCatName = value;
                  },
                ),
                const SizedBox(height: 20),
                const Text('选择颜色:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                // 颜色调色盘
                _buildColorPalette(selectedColor, (color) {
                  setDialogState(() {
                    selectedColor = color;
                    hexColor =
                        '${(color.value).toRadixString(16).toUpperCase().padLeft(8, '0').substring(2)}';
                  });
                }),
                const SizedBox(height: 12),
                // 颜色预览
                Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: selectedColor,
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('十六进制颜色代码:',
                              style: TextStyle(fontSize: 12)),
                          TextField(
                            decoration: const InputDecoration(
                              hintText: '输入十六进制代码 (如: FF2196F3)',
                              prefixText: '#',
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                            ),
                            controller: TextEditingController(text: hexColor),
                            onChanged: (value) {
                              try {
                                // 移除 # 号并处理输入
                                String cleanValue =
                                    value.replaceAll('#', '').toUpperCase();
                                if (cleanValue.length == 6) {
                                  cleanValue = 'FF' + cleanValue;
                                } else if (cleanValue.length != 8) {
                                  return;
                                }
                                final color = Color(int.parse('0x$cleanValue'));
                                setDialogState(() {
                                  selectedColor = color;
                                  hexColor = cleanValue;
                                });
                              } catch (e) {
                                // 无效的颜色代码，忽略
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 预设颜色快速选择
                const Text('预设颜色:', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Colors.red,
                    Colors.blue,
                    Colors.green,
                    Colors.orange,
                    Colors.purple,
                    Colors.cyan,
                    Colors.pink,
                    Colors.amber,
                    Colors.teal,
                    Colors.indigo,
                    const Color(0xFFD4AF37),
                    const Color(0xFF9CB86A),
                  ].map((color) {
                    return GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedColor = color;
                          hexColor =
                              '${(color.value).toRadixString(16).toUpperCase().padLeft(8, '0').substring(2)}';
                        });
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          border: Border.all(
                            color: selectedColor == color
                                ? Colors.black
                                : Colors.grey,
                            width: selectedColor == color ? 3 : 1,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (newCatName.isNotEmpty) {
                  provider.addCategory(Category(
                    name: newCatName,
                    color: selectedColor,
                  ));
                  Navigator.pop(context);
                }
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  // 生成渐变颜色调色盘
  Widget _buildColorPalette(
      Color currentColor, Function(Color) onColorChanged) {
    // 生成一个颜色矩阵：水平是色调，垂直是亮度
    List<Color> hues = [
      Colors.red,
      Colors.orange,
      Colors.yellow,
      Colors.green,
      Colors.cyan,
      Colors.blue,
      Colors.purple,
      Colors.pink,
    ];

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: List.generate(8, (row) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: List.generate(8, (col) {
                Color baseColor = hues[col];
                // 根据行数调整亮度
                double brightness = 0.3 + (row / 7) * 0.7;
                Color color = Color.lerp(
                  Colors.black,
                  baseColor,
                  brightness,
                )!;

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: GestureDetector(
                      onTap: () => onColorChanged(color),
                      child: Container(
                        height: 20,
                        decoration: BoxDecoration(
                          color: color,
                          border: Border.all(
                            color: currentColor == color
                                ? Colors.white
                                : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          );
        }),
      ),
    );
  }

  void _showAddSubCategoryDialog(
      BuildContext context, int catIndex, Category cat, TimeProvider provider) {
    String newSubCatName = '';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加子事件'),
        content: TextField(
          decoration: const InputDecoration(
            labelText: '子事件名称',
            hintText: '请输入子事件名称',
          ),
          onChanged: (value) {
            newSubCatName = value;
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (newSubCatName.isNotEmpty) {
                List<String> newSubs = List.from(cat.subCategories);
                newSubs.add(newSubCatName);
                Category newCat = cat.copyWith(subCategories: newSubs);
                provider.updateCategory(catIndex, newCat);
                Navigator.pop(context);
              }
            },
            child: const Text('添加'),
          ),
        ],
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
