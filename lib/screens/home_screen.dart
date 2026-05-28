import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/category.dart';
import 'dart:async';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:reorderables/reorderables.dart';
import '../widgets/date_picker_panel.dart';
import '../widgets/template_bar.dart';
import '../models/schedule_template.dart';
import 'global_search_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey _gridKey = GlobalKey();
  // 使用初始化好的控制器，解决 late 初始化可能导致的 Bug
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _syncSubscription;

  int? _dragStartIndex;
  int? _dragEndIndex;

  // 管理分类的展开状态
  final Map<int, bool> _expandedCategories = {};
  bool _isDatePickerVisible = false;

  @override
  void initState() {
    super.initState();
    // 初始滚动到配置的开始时间
    final timeProvider = Provider.of<TimeProvider>(context, listen: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 在第一帧构建完成后执行滚动
      _scrollController.jumpTo(timeProvider.startHour * 45.0);
    });

    // 监听同步状态并显示提示
    _syncSubscription = timeProvider.syncStatusStream.listen((message) {
      // 只对最终状态（成功/失败）的消息弹出提示，避免 "SYNCING" 和 "IDLE" 弹出
      if (mounted && message != "SYNCING" && message != "IDLE") {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(message), duration: const Duration(seconds: 2)),
        );
      }
    });
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
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
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: isDark ? colorScheme.surface : const Color(0xFF9CB86A),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        title: _buildAppBarTitle(timeProvider, timeProvider.currentDate),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        key: _gridKey,
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: 24,
                        itemBuilder: (context, h) =>
                            _buildIntegratedRow(h, timeProvider),
                      ),
                    ),
                    _buildCategorySidebar(timeProvider),
                  ],
                ),
              ),
              StreamBuilder<String>(
                stream: timeProvider.syncStatusStream,
                builder: (context, snapshot) {
                  final status = snapshot.data ?? "IDLE";
                  if (status == "SYNCING") {
                    return const LinearProgressIndicator(
                      backgroundColor: Colors.transparent,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFF9CB86A)),
                      minHeight: 3,
                    );
                  }
                  return const SizedBox(height: 3);
                },
              ),
            ],
          ),
          if (_isDatePickerVisible) ...[
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _isDatePickerVisible = false),
                child: Container(color: Colors.black54),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: DatePickerPanel(
                initialDate: timeProvider.currentDate,
                onDateSelected: (selected) {
                  timeProvider.goToDate(selected);
                  setState(() {
                    _isDatePickerVisible = false;
                    _dragStartIndex = null;
                    _dragEndIndex = null;
                  });
                },
                onClose: () => setState(() => _isDatePickerVisible = false),
              ),
            ),
          ],
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
            "${h.toString().padLeft(2, '0')}:00", // 显示实际小时数
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
        ),
        // 右侧网格
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                // 关键：点击事件
                onTapDown: (d) =>
                    _handleSelect(d.globalPosition, isClick: true),
                // 双击删除单个时间块的事件
                onDoubleTapDown: (d) {
                  // 使用局部坐标计算，比全局计算更稳定
                  double width = constraints.maxWidth;
                  int col =
                      (d.localPosition.dx / (width / 6)).floor().clamp(0, 5);
                  int index = h * 6 + col;
                  provider.removeEventFromSlot(index);
                },
                onDoubleTap: () {}, // 必须注册 onDoubleTap 以启用双击手势识别
                // 关键：滑动开始时，传入 isStart: true 来重置索引
                onPanStart: (d) =>
                    _handleSelect(d.globalPosition, isStart: true),
                onPanUpdate: (d) => _handleSelect(d.globalPosition),
                child: Container(
                  child: _buildGridRow(h, provider),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGridRow(int h, TimeProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final highlightColor = colorScheme.primary.withValues(alpha: 0.28);
    final emptyCellColor = isDark
        ? colorScheme.surfaceContainerHigh
        : const Color.fromARGB(255, 188, 186, 186);

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
                        ? highlightColor
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
                        ? highlightColor
                        : emptyCellColor,
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
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: 100,
      color: isDark ? colorScheme.surfaceContainerLow : Colors.grey[100],
      child: Column(
        children: [
          TemplateBar(
            provider: provider,
            onTemplateTap: (template) => _onTemplateTap(template, provider),
            onManageTap: () => _showTemplateManageSheet(provider),
            onCopyYesterdayTap: () => _onCopyYesterday(provider),
          ),
          Expanded(
            child: ReorderableListView.builder(
              // 1. 核心排序逻辑
              itemCount: provider.categories.length,
              onReorder: (oldIndex, newIndex) {
                provider.reorderCategories(oldIndex, newIndex);
              },

              // 2. 补齐底部添加按钮
              footer: Padding(
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

              // 3. 列表项构建
              itemBuilder: (context, index) {
                final category = provider.categories[index];

                return Slidable(
                  // Slidable 必须有唯一的 Key 才能在排序时保持状态
                  key: ValueKey('slidable_${category.name}_$index'),

                  // 配置左滑删除按钮
                  endActionPane: ActionPane(
                    motion: const DrawerMotion(),
                    extentRatio: 0.6, // 侧滑展开的宽度比例
                    children: [
                      SlidableAction(
                        onPressed: (context) => _showDeleteConfirmDialog(
                            context, index, category, provider),
                        backgroundColor: const Color(0xFFFE4A49),
                        foregroundColor: Colors.white,
                        icon: Icons.delete,
                        label: '删除',
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ],
                  ),

                  // 包装原有的分类 UI
                  child: _buildCategoryItem(index, category, provider),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryItem(int catIndex, Category cat, TimeProvider provider) {
    bool isExpanded = _expandedCategories[catIndex] ?? true;
    bool isTemporary = cat.name == '临时';

    return Column(
      children: [
        // 事件项
        InkWell(
          onTap: () => isTemporary
              ? _showTemporaryEventDialog(provider)
              : _assignCategory(cat, provider),
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
                if (!isTemporary)
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
        if (isExpanded && !isTemporary)
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
                GestureDetector(
                  onTap: () => _showCategoryDialog(context, provider,
                      index: catIndex, existingCat: cat), // 统一调用
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    decoration: BoxDecoration(
                      color: cat.color.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white, width: 1),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.edit,
                            color: Colors.white, size: 14), // 修改图标为编辑
                        SizedBox(width: 4),
                        Text('编辑',
                            style:
                                TextStyle(color: Colors.white, fontSize: 11)),
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
      provider.assignCategoryToSlots(rangeIndices, cat, subLabel: subCat);
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

  void _showTemporaryEventDialog(TimeProvider provider) {
    if (_dragStartIndex == null || _dragEndIndex == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("请先在左侧网格中选择时间块"), duration: Duration(seconds: 2)),
      );
      return;
    }

    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("请输入临时事件名称"),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(hintText: "名称尽量短"),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消"),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.isNotEmpty) {
                  Category tempCat =
                      Category(name: nameController.text, color: Colors.grey);
                  _assignCategory(tempCat, provider);
                  Navigator.pop(context);
                }
              },
              child: const Text("确认"),
            ),
          ],
        );
      },
    );
  }

  void _showCategoryDialog(BuildContext context, TimeProvider provider,
      {int? index, Category? existingCat}) {
    bool isEdit = index != null && existingCat != null;

    String catName = isEdit ? existingCat.name : '';
    Color selectedColor = isEdit ? existingCat.color : Colors.blue;
    List<String> tempSubCategories =
        isEdit ? List.from(existingCat.subCategories) : [];

    final nameController = TextEditingController(text: catName);
    final subCatController = TextEditingController();

    String currentHex = (selectedColor.toARGB32())
        .toRadixString(16)
        .toUpperCase()
        .padLeft(8, '0')
        .substring(2);
    final hexController = TextEditingController(text: currentHex);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(isEdit ? '编辑事件' : '添加事件',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: MediaQuery.of(context).size.width * 0.8,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. 事件名称
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: '事件名称'),
                      onChanged: (value) => catName = value,
                    ),
                    const SizedBox(height: 20),

                    // 2. 颜色选择器
                    const Text('选择颜色:',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    _buildColorPalette(selectedColor, (color) {
                      setDialogState(() {
                        selectedColor = color;
                        hexController.text = (color.toARGB32())
                            .toRadixString(16)
                            .toUpperCase()
                            .padLeft(8, '0')
                            .substring(2);
                      });
                    }),

                    // 3. 十六进制输入
                    TextField(
                      controller: hexController,
                      decoration: const InputDecoration(
                        labelText: '十六进制代码',
                        prefixText: '#',
                        border: InputBorder.none, // 移除自带下划线
                        isDense: true,
                      ),
                      onChanged: (value) {
                        try {
                          String clean =
                              value.replaceAll('#', '').toUpperCase();
                          if (clean.length == 6) clean = 'FF$clean';
                          if (clean.length == 8) {
                            setDialogState(() =>
                                selectedColor = Color(int.parse('0x$clean')));
                          }
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    '请输入合法的6位/8位十六进制颜色值（如 #FFFFFF 或 #FFFFFFFF）')),
                          );
                        }
                      },
                    ),

                    // 统一的单分隔线
                    const Divider(height: 1, thickness: 1),
                    const SizedBox(height: 15),

                    // 4. 子事件区域
                    Text('编辑子事件 (点击删除，长按拖动排序)',
                        style:
                            TextStyle(color: Colors.grey[600], fontSize: 11)),
                    const SizedBox(height: 10),

                    // 横向可排序标签组
                    ReorderableWrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      onReorder: (oldIndex, newIndex) {
                        setDialogState(() {
                          final String item =
                              tempSubCategories.removeAt(oldIndex);
                          tempSubCategories.insert(newIndex, item);
                        });
                      },
                      children: tempSubCategories.asMap().entries.map((entry) {
                        return GestureDetector(
                          key: ValueKey('sub_chip_${entry.value}_${entry.key}'),
                          onTap: () => setDialogState(
                              () => tempSubCategories.removeAt(entry.key)),
                          child: Chip(
                            visualDensity: VisualDensity.compact,
                            backgroundColor:
                                selectedColor.withValues(alpha: 0.8),
                            label: Text(entry.value,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12)),
                            deleteIcon: const Icon(Icons.close,
                                size: 14, color: Colors.white70),
                            onDeleted: () => setDialogState(
                                () => tempSubCategories.removeAt(entry.key)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            side: BorderSide.none,
                          ),
                        );
                      }).toList(),
                    ),

                    // 5. 添加子事件输入
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: subCatController,
                            decoration: const InputDecoration(
                                hintText: '添加子事件', isDense: true),
                            onSubmitted: (val) {
                              if (val.isNotEmpty) {
                                setDialogState(() {
                                  tempSubCategories.add(val);
                                  subCatController.clear();
                                });
                              }
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle,
                              color: Color(0xFF9CB86A)),
                          onPressed: () {
                            if (subCatController.text.isNotEmpty) {
                              setDialogState(() {
                                tempSubCategories.add(subCatController.text);
                                subCatController.clear();
                              });
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9CB86A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  if (catName.isNotEmpty) {
                    Category newCat = Category(
                      id: isEdit ? provider.categories[index].id : null,
                      name: catName,
                      color: selectedColor,
                      subCategories: tempSubCategories,
                    );
                    isEdit
                        ? provider.updateCategory(index, newCat)
                        : provider.addCategory(newCat);
                    Navigator.pop(context);
                  }
                },
                child: Text(isEdit ? '保存修改' : '确认添加'),
              ),
            ],
          );
        },
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

  String _syncButtonTooltip(TimeProvider provider) {
    if (!provider.hasPendingSyncForCurrentDate) return '同步到日历';
    if (!provider.canSyncToCalendar) return '本地已改，登录后可同步到日历';
    return '待同步到日历';
  }

  Widget _appBarIconButton({
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
    double? iconSize,
    Widget? iconWidget,
    bool compact = false,
  }) {
    final size = iconSize ?? (compact ? 16.0 : 23.0);
    final minSide = compact ? 32.0 : 40.0;
    final minHeight = compact ? 40.0 : 48.0;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(minWidth: minSide, minHeight: minHeight),
      icon: iconWidget ?? Icon(icon, size: size),
    );
  }

  Widget _buildAppBarTitle(TimeProvider provider, DateTime date) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        _appBarIconButton(
          icon: Icons.arrow_back_ios,
          compact: true,
          onPressed: () => provider.previousDay(),
        ),
        GestureDetector(
          onTap: () => _showDatePicker(),
          child: Text(
            "${date.month}月${date.day}日",
            style: TextStyle(
              decoration: TextDecoration.underline,
              decorationColor:
                  isDark ? colorScheme.onSurfaceVariant : Colors.white70,
            ),
          ),
        ),
        _appBarIconButton(
          icon: Icons.arrow_forward_ios,
          compact: true,
          onPressed: () => provider.nextDay(),
        ),
        const Expanded(child: SizedBox()),
        _appBarIconButton(
          icon: Icons.search,
          tooltip: '搜索记录',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const GlobalSearchScreen(),
              ),
            );
          },
        ),
        _appBarIconButton(
          icon: Icons.undo,
          onPressed: () => provider.undo(),
        ),
        _appBarIconButton(
          icon: Icons.delete_sweep,
          onPressed: () => _showClearDialog(context, provider),
        ),
        _appBarIconButton(
          tooltip: _syncButtonTooltip(provider),
          icon: Icons.sync,
          onPressed: () => provider.synchronizeCalendar(),
          iconWidget: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.sync, size: 23),
              if (provider.hasPendingSyncForCurrentDate)
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _showDatePicker() {
    setState(() => _isDatePickerVisible = true);
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

  void _onTemplateTap(ScheduleTemplate template, TimeProvider provider) {
    if (provider.hasTemplateConflictWithCurrentDay(template.id)) {
      _showApplyTemplateDialog(template, provider);
    } else {
      provider.applyTemplate(template.id, ApplyTemplateMode.fillEmptyOnly);
    }
  }

  void _onCopyYesterday(TimeProvider provider) {
    if (!provider.hasYesterdayToCopy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('昨天没有可复制的记录'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (provider.hasCopyYesterdayConflict()) {
      _showCopyYesterdayDialog(provider);
    } else {
      provider.copyFromYesterday();
    }
  }

  void _showCopyYesterdayDialog(TimeProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('复制昨天安排'),
        content: const Text('当天部分时段已有不同记录，请选择复制方式：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              provider.copyFromYesterday(
                  mode: ApplyTemplateMode.fillEmptyOnly);
              Navigator.pop(context);
            },
            child: const Text('仅填充空白'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9CB86A),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              provider.copyFromYesterday(mode: ApplyTemplateMode.replaceAll);
              Navigator.pop(context);
            },
            child: const Text('覆盖全天'),
          ),
        ],
      ),
    );
  }

  void _showApplyTemplateDialog(
      ScheduleTemplate template, TimeProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('套用「${template.name}」'),
        content: const Text('当天部分时段已有不同记录，请选择套用方式：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              provider.applyTemplate(
                  template.id, ApplyTemplateMode.fillEmptyOnly);
              Navigator.pop(context);
            },
            child: const Text('仅填充空白'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9CB86A),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              provider.applyTemplate(template.id, ApplyTemplateMode.replaceAll);
              Navigator.pop(context);
            },
            child: const Text('覆盖全天'),
          ),
        ],
      ),
    );
  }

  void _showTemplateManageSheet(TimeProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final templates = provider.templates;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                      child: Row(
                        children: [
                          const Text(
                            '模板管理',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ),
                    if (templates.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '暂无模板，可从今日记录保存',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: templates.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final t = templates[index];
                            return ListTile(
                              title: Text(t.name),
                              subtitle: Text('共 ${t.slots.length} 格'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined,
                                        size: 20),
                                    onPressed: () {
                                      _showRenameTemplateDialog(
                                        t,
                                        provider,
                                        onRenamed: () => setSheetState(() {}),
                                      );
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 20, color: Colors.red),
                                    onPressed: () {
                                      provider.deleteTemplate(t.id);
                                      setSheetState(() {});
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF9CB86A),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          icon: const Icon(Icons.save_alt),
                          label: const Text('从今日保存新模板'),
                          onPressed: () {
                            _showSaveTemplateDialog(
                              provider,
                              onSaved: () => setSheetState(() {}),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSaveTemplateDialog(TimeProvider provider,
      {VoidCallback? onSaved}) {
    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存为模板'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            hintText: '例如：周一、工作日',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9CB86A),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final ok =
                  provider.saveTemplateFromCurrentDay(nameController.text);
              Navigator.pop(context);
              if (!ok) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(
                    content: Text('今天还没有可保存的记录'),
                    duration: Duration(seconds: 2),
                  ),
                );
              } else {
                onSaved?.call();
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showRenameTemplateDialog(
    ScheduleTemplate template,
    TimeProvider provider, {
    VoidCallback? onRenamed,
  }) {
    final nameController = TextEditingController(text: template.name);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名模板'),
        content: TextField(
          controller: nameController,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9CB86A),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              provider.renameTemplate(template.id, nameController.text);
              Navigator.pop(context);
              onRenamed?.call();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmDialog(
      BuildContext context, int index, Category cat, TimeProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("确认删除"),
        content: Text("确定要删除“${cat.name}”及其所有子事件吗？"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              provider.deleteCategory(index); // 在 Provider 中实现此方法
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text("删除"),
          ),
        ],
      ),
    );
  }
}
