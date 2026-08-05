import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';
import '../models/category.dart';
import '../models/schedule_template.dart';
import '../providers/time_provider.dart';
import '../widgets/date_picker_panel.dart';
import '../widgets/template_bar.dart';
import '../widgets/time_grid.dart';
import 'daily_review_screen.dart';
import 'global_search_screen.dart';

/// Windows 三列视图下列头高度，与左侧时间标签占位共用，保证对齐。
const double _kDayHeaderHeight = 40;
const List<String> _kWeekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey _gridKey = GlobalKey();
  // 左侧时间轴滚动；右侧网格跟随同步，自身不可滚动
  final ScrollController _scrollController = ScrollController();
  final ScrollController _gridScrollController = ScrollController();
  StreamSubscription? _syncSubscription;

  // 当前选中待分配的范围（跨平台统一）。
  // Windows 双列下由各 _DayGrid 上报其日期，安卓恒为当前日期。
  int? _selectionStart;
  int? _selectionEnd;
  DateTime? _selectionDate;

  bool _isDatePickerVisible = false;

  @override
  void initState() {
    super.initState();
    // 初始滚动到配置的开始时间
    final timeProvider = Provider.of<TimeProvider>(context, listen: false);
    _scrollController.addListener(_syncGridScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final offset = timeProvider.startHour * 45.0;
      _scrollController.jumpTo(offset);
      if (_gridScrollController.hasClients) {
        _gridScrollController.jumpTo(offset);
      }
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
    _scrollController.removeListener(_syncGridScroll);
    _scrollController.dispose();
    _gridScrollController.dispose();
    super.dispose();
  }

  void _syncGridScroll() {
    if (!_gridScrollController.hasClients) return;
    final target = _scrollController.offset;
    if ((_gridScrollController.offset - target).abs() > 0.5) {
      _gridScrollController.jumpTo(target);
    }
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
    int col = (localOffset.dx / (gridWidth / 6)).floor().clamp(0, 5);

    return row * 6 + col;
  }

  void _handleSelect(Offset globalPosition, DateTime date,
      {bool isClick = false, bool isStart = false}) {
    final currentIndex = _calculateIndex(globalPosition);

    setState(() {
      if (isClick) {
        // --- 逻辑修复：点击切换 ---
        // 如果当前已经选中了东西，且点击的是选中的范围，则清空
        if (_selectionStart == currentIndex && _selectionEnd == currentIndex) {
          _selectionStart = null;
          _selectionEnd = null;
          _selectionDate = null;
        } else {
          // 否则，单选当前格子
          _selectionStart = currentIndex;
          _selectionEnd = currentIndex;
          _selectionDate = date;
        }
      } else {
        // --- 逻辑修复：滑动逻辑 ---
        if (isStart) {
          // 每次重新开始滑动时，重置起始点和终点为当前点
          _selectionStart = currentIndex;
        }
        _selectionEnd = currentIndex;
        _selectionDate = date;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final timeProvider = context.read<TimeProvider>();
    final currentDate =
        context.select<TimeProvider, DateTime>((p) => p.currentDate);
    // Windows 三列视图：以选中日为中间，左右各一天
    final prevDate = currentDate.subtract(const Duration(days: 1));
    final nextDate = currentDate.add(const Duration(days: 1));
    final googleSyncEnabled = context.select<TimeProvider, bool>(
        (p) => p.googleCalendarSyncEnabled);
    final isRemoteViewEnabled = context.select<TimeProvider, bool>(
        (p) => p.isRemoteViewEnabled);
    final hasPendingSyncForCurrentDate = context.select<TimeProvider, bool>(
        (p) => p.hasPendingSyncForCurrentDate);
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: isDark ? colorScheme.surface : const Color(0xFF9CB86A),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 8,
        // 仅 Windows：切换日期的按钮居中；安卓保持默认左对齐
        centerTitle: Platform.isWindows,
        actionsPadding: const EdgeInsets.only(right: 15),
        title: _buildAppBarDateNav(timeProvider, currentDate),
        actions: _buildAppBarActions(
          timeProvider,
          currentDate,
          googleSyncEnabled,
          isRemoteViewEnabled,
          hasPendingSyncForCurrentDate,
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 55,
                            child: Column(
                              children: [
                                // Windows 下与右侧列头对齐的占位
                                if (Platform.isWindows)
                                  const SizedBox(height: _kDayHeaderHeight),
                                Expanded(
                                  child: ListView.builder(
                                    controller: _scrollController,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 8),
                                    itemCount: 24,
                                    itemExtent: 45,
                                    itemBuilder: (context, h) =>
                                        _buildTimeLabelRow(h),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  if (Platform.isWindows)
                    Expanded(
                      child: Column(
                        children: [
                          // 三列日期头（插入与网格行相同的分割线占位以保持列宽一致）
                          Row(
                            children: [
                              Expanded(child: _DayHeader(date: prevDate)),
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
                              Expanded(child: _DayHeader(date: nextDate)),
                            ],
                          ),
                          // 三列网格：昨天 / 今天 / 明天
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: _DayGrid(
                                    date: prevDate,
                                    timeAxisController: _scrollController,
                                    onSelectionChanged: (date, start, end) {
                                      setState(() {
                                        _selectionDate = date;
                                        _selectionStart = start;
                                        _selectionEnd = end;
                                      });
                                    },
                                    onRemoveSlot: (date, index) =>
                                        timeProvider.removeEventFromSlot(
                                            index,
                                            date: date),
                                  ),
                                ),
                                const VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: Color(0x33000000),
                                ),
                                Expanded(
                                  child: _DayGrid(
                                    date: currentDate,
                                    timeAxisController: _scrollController,
                                    onSelectionChanged: (date, start, end) {
                                      setState(() {
                                        _selectionDate = date;
                                        _selectionStart = start;
                                        _selectionEnd = end;
                                      });
                                    },
                                    onRemoveSlot: (date, index) =>
                                        timeProvider.removeEventFromSlot(
                                            index,
                                            date: date),
                                  ),
                                ),
                                const VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: Color(0x33000000),
                                ),
                                Expanded(
                                  child: _DayGrid(
                                    date: nextDate,
                                    timeAxisController: _scrollController,
                                    onSelectionChanged: (date, start, end) {
                                      setState(() {
                                        _selectionDate = date;
                                        _selectionStart = start;
                                        _selectionEnd = end;
                                      });
                                    },
                                    onRemoveSlot: (date, index) =>
                                        timeProvider.removeEventFromSlot(
                                            index,
                                            date: date),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Expanded(
                      child: TimeGrid(
                        gridKey: _gridKey,
                        controller: _gridScrollController,
                        dragStartIndex: _selectionStart,
                        dragEndIndex: _selectionEnd,
                        onTapDown: (position) => _handleSelect(position,
                            currentDate, isClick: true),
                        onPanStart: (position) => _handleSelect(position,
                            currentDate, isStart: true),
                        onPanUpdate: (position) =>
                            _handleSelect(position, currentDate),
                        onRemoveSlot: (index) =>
                            timeProvider.removeEventFromSlot(index),
                      ),
                    ),
                        ],
                      ),
                    ),
                    Selector<TimeProvider, ({int categoriesRevision, int templatesRevision, DateTime currentDate})>(
                      selector: (_, p) => (
                        categoriesRevision: p.categoriesRevision,
                        templatesRevision: p.templatesRevision,
                        currentDate: p.currentDate,
                      ),
                      builder: (context, data, _) =>
                          _buildCategorySidebar(timeProvider),
                    ),
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
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    // 仅 Windows 限制宽度，避免宽屏下日历格子等比放大；安卓保持整宽
                    maxWidth: Platform.isWindows ? 360 : double.infinity,
                  ),
                  child: DatePickerPanel(
                    initialDate: currentDate,
                    onDateSelected: (selected) {
                      timeProvider.goToDate(selected);
                      setState(() {
                        _isDatePickerVisible = false;
                        _selectionStart = null;
                        _selectionEnd = null;
                        _selectionDate = null;
                      });
                    },
                    onClose: () =>
                        setState(() => _isDatePickerVisible = false),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTimeLabelRow(int h) {
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
    bool isExpanded = provider.getCategoryExpandState(cat.id);
    bool isTemporary = cat.name == '临时';

    return Column(
      children: [
        // 事件项 - 使用 Row 将展开按钮和事件分开
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              // 展开按钮 - 使用 Listener 处理原始点击，避免与 Slidable/Reorderable 手势冲突
              // 通过记录 down 位置过滤拖动操作，只有 down/up 位置接近才视为点击
              if (!isTemporary)
                _ExpandButton(
                  isExpanded: isExpanded,
                  onTap: () {
                    final currentExpanded =
                        provider.getCategoryExpandState(cat.id);
                    provider.setCategoryExpandState(cat.id, !currentExpanded);
                  },
                ),
              // 事件主体 - 可点击分配分类
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => isTemporary
                      ? _showTemporaryEventDialog(provider)
                      : _assignCategory(cat, provider),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    decoration: BoxDecoration(
                      color: cat.color,
                      borderRadius: BorderRadius.circular(6),
                    ),
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
                ),
              ),
            ],
          ),
        ),
        // 展开后显示子事件
        if (isExpanded && !isTemporary)
          Padding(
            padding: const EdgeInsets.only(left: 8.0, right: 4.0),
            child: Column(
              children: [
                ...cat.subCategories.asMap().entries.map((entry) {
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
                        ],
                      ),
                    ),
                  );
                }),
                GestureDetector(
                  onTap: () => _showCategoryDialog(context, provider,
                      index: catIndex, existingCat: cat),
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
                        Icon(Icons.edit, color: Colors.white, size: 14),
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
    if (_selectionStart != null && _selectionEnd != null) {
      int s = _selectionStart! < _selectionEnd!
          ? _selectionStart!
          : _selectionEnd!;
      int e = _selectionStart! < _selectionEnd!
          ? _selectionEnd!
          : _selectionStart!;
      Set<int> rangeIndices = {};
      for (int i = s; i <= e; i++) {
        rangeIndices.add(i);
      }
      provider.assignCategoryToSlots(rangeIndices, cat, date: _selectionDate);
      setState(() {
        _selectionStart = null;
        _selectionEnd = null;
        _selectionDate = null;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("请先在左侧网格中选择时间块"), duration: Duration(seconds: 2)),
      );
    }
  }

  void _assignSubCategory(Category cat, String subCat, TimeProvider provider) {
    if (_selectionStart != null && _selectionEnd != null) {
      int s = _selectionStart! < _selectionEnd!
          ? _selectionStart!
          : _selectionEnd!;
      int e = _selectionStart! < _selectionEnd!
          ? _selectionEnd!
          : _selectionStart!;
      Set<int> rangeIndices = {};
      for (int i = s; i <= e; i++) {
        rangeIndices.add(i);
      }
      provider.assignCategoryToSlots(rangeIndices, cat,
          subLabel: subCat, date: _selectionDate);
      setState(() {
        _selectionStart = null;
        _selectionEnd = null;
        _selectionDate = null;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("请先在左侧网格中选择时间块"), duration: Duration(seconds: 2)),
      );
    }
  }

  void _showTemporaryEventDialog(TimeProvider provider) {
    if (_selectionStart == null || _selectionEnd == null) {
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
    ).whenComplete(() => nameController.dispose());
  }

  void _showSubCategoryMenu({
    required BuildContext context,
    required String subCat,
    required int subIndex,
    required StateSetter setDialogState,
    required List<String> tempSubCategories,
    required String currentCategoryId,
    required List<Category> allCategories,
    required Function(String fromCategoryId, String toCategoryId, String name)
        onMove,
  }) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('确认删除'),
                    content: Text('确定要删除子事件"$subCat"吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () {
                          setDialogState(
                              () => tempSubCategories.removeAt(subIndex));
                          Navigator.pop(context);
                        },
                        style:
                            TextButton.styleFrom(foregroundColor: Colors.red),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.move_to_inbox),
              title: const Text('移动到...'),
              onTap: () {
                Navigator.pop(context);
                _showMoveSubCategoryDialog(
                  context: context,
                  subCat: subCat,
                  currentCategoryId: currentCategoryId,
                  allCategories: allCategories,
                  onMove: onMove,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showMoveSubCategoryDialog({
    required BuildContext context,
    required String subCat,
    required String currentCategoryId,
    required List<Category> allCategories,
    required Function(String fromCategoryId, String toCategoryId, String name)
        onMove,
  }) {
    String? selectedCategoryId;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('移动到...'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: allCategories
                .where((c) => c.id != currentCategoryId)
                .map((category) => RadioListTile<String>(
                      title: Text(category.name),
                      value: category.id,
                      groupValue: selectedCategoryId,
                      onChanged: (value) {
                        setDialogState(() => selectedCategoryId = value);
                      },
                    ))
                .toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selectedCategoryId == null
                  ? null
                  : () {
                      final targetCat = allCategories
                          .firstWhere((c) => c.id == selectedCategoryId);
                      onMove(currentCategoryId, selectedCategoryId!, subCat);
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已将"$subCat"移动到${targetCat.name}'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
              child: const Text('移动'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCategoryDialog(BuildContext context, TimeProvider provider,
      {int? index, Category? existingCat}) {
    bool isEdit = index != null && existingCat != null;

    String catName = isEdit ? existingCat.name : '';
    Color selectedColor = isEdit ? existingCat.color : Colors.blue;
    List<String> tempSubCategories =
        isEdit ? List.from(existingCat.subCategories) : [];
    List<String> tempHiddenSubCategories =
        isEdit ? List.from(existingCat.hiddenSubCategories) : [];

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
                    Text('编辑子事件 (点击删除，拖动到下方隐藏)',
                        style:
                            TextStyle(color: Colors.grey[600], fontSize: 11)),
                    const SizedBox(height: 10),

                    // 子事件列表
                    if (tempSubCategories.isNotEmpty)
                      _ReorderableChipWrap(
                        items: tempSubCategories,
                        color: selectedColor,
                        onReorder: (oldIndex, newIndex) {
                          setDialogState(() {
                            final item = tempSubCategories.removeAt(oldIndex);
                            tempSubCategories.insert(newIndex, item);
                          });
                        },
                        onTap: (subCat, subIndex) => _showSubCategoryMenu(
                          context: context,
                          subCat: subCat,
                          subIndex: subIndex,
                          setDialogState: setDialogState,
                          tempSubCategories: tempSubCategories,
                          currentCategoryId:
                              isEdit ? provider.categories[index].id : '',
                          allCategories: provider.categories,
                          onMove: (fromCategoryId, toCategoryId, name) {
                            provider.moveSubCategory(
                                fromCategoryId, toCategoryId, name);
                          },
                        ),
                      ),

                    // 隐藏区域
                    const SizedBox(height: 10),
                    DragTarget<String>(
                      onWillAcceptWithDetails: (details) {
                        return tempSubCategories.contains(details.data);
                      },
                      onAcceptWithDetails: (details) {
                        setDialogState(() {
                          tempSubCategories.remove(details.data);
                          tempHiddenSubCategories.add(details.data);
                        });
                      },
                      builder: (context, candidateData, rejectedData) {
                        final isHovering = candidateData.isNotEmpty;
                        return Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 12),
                          decoration: BoxDecoration(
                            color: isHovering
                                ? Colors.orange.withValues(alpha: 0.3)
                                : Colors.grey.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isHovering ? Colors.orange : Colors.grey,
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.visibility_off,
                                  color:
                                      isHovering ? Colors.orange : Colors.grey,
                                  size: 16),
                              const SizedBox(width: 8),
                              Text(
                                isHovering ? '释放以隐藏' : '拖动子事件到此处隐藏',
                                style: TextStyle(
                                  color:
                                      isHovering ? Colors.orange : Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
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

                    // 6. 隐藏的子事件区域
                    if (tempHiddenSubCategories.isNotEmpty) ...[
                      const SizedBox(height: 15),
                      const Divider(height: 1, thickness: 1),
                      const SizedBox(height: 10),
                      Text('已隐藏的子事件 (点击恢复)',
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 11)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8.0,
                        runSpacing: 8.0,
                        children: tempHiddenSubCategories
                            .map((hiddenSubCat) {
                          return ActionChip(
                            avatar: const Icon(Icons.restore,
                                size: 14, color: Colors.grey),
                            label: Text(hiddenSubCat,
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12)),
                            backgroundColor: Colors.grey.withValues(alpha: 0.2),
                            onPressed: () {
                              setDialogState(() {
                                tempHiddenSubCategories.remove(hiddenSubCat);
                                tempSubCategories.add(hiddenSubCat);
                              });
                            },
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            side: BorderSide(
                                color: Colors.grey.withValues(alpha: 0.4)),
                          );
                        }).toList(),
                      ),
                    ],
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
                      hiddenSubCategories: tempHiddenSubCategories,
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
    ).whenComplete(() {
      nameController.dispose();
      subCatController.dispose();
      hexController.dispose();
    });
  }
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

  Widget _buildAppBarDateNav(TimeProvider provider, DateTime date) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _appBarIconButton(
          icon: Icons.arrow_back_ios,
          compact: true,
          onPressed: () {
            _clearSelection();
            provider.previousDay();
          },
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
          onPressed: () {
            _clearSelection();
            provider.nextDay();
          },
        ),
      ],
    );
  }

  List<Widget> _buildAppBarActions(
    TimeProvider provider,
    DateTime date,
    bool googleSyncEnabled,
    bool remoteViewEnabled,
    bool hasPendingSyncForCurrentDate,
  ) {
    return [
      _appBarIconButton(
        icon: Icons.auto_awesome,
        tooltip: '每日复盘',
        onPressed: () => DailyReviewScreen.open(context, date: date),
      ),
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
        tooltip: '撤销',
        onPressed: () => provider.undo(),
      ),
      _appBarIconButton(
        tooltip: remoteViewEnabled ? '关闭对方日程' : '查看对方日程',
        icon: Icons.people_outline,
        iconWidget: StreamBuilder<String>(
          stream: provider.scheduleGiteeSyncStream,
          initialData: '',
          builder: (context, snapshot) {
            final status = snapshot.data ?? '';
            return Tooltip(
              message: remoteViewEnabled
                  ? (status.isNotEmpty ? status : '点击关闭对方日程')
                  : '查看对方日程',
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    Icons.people_outline,
                    size: 23,
                    color: remoteViewEnabled ? Colors.blue : null,
                  ),
                  if (remoteViewEnabled)
                    const Positioned(
                      right: -4,
                      top: -4,
                      child: Icon(Icons.check_circle, size: 12, color: Colors.blue),
                    ),
                ],
              ),
            );
          },
        ),
        onPressed: () => provider.toggleRemoteScheduleView(),
      ),
      _appBarIconButton(
        tooltip: googleSyncEnabled ?
            '同步到 Gitee 和 Google 日历' :
            '同步日程到 Gitee',
        icon: Icons.sync,
        onPressed: () => provider.syncAll(),
        iconWidget: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(Icons.sync, size: 23),
            if (hasPendingSyncForCurrentDate)
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
    ];
  }

  void _clearSelection() {
    setState(() {
      _selectionStart = null;
      _selectionEnd = null;
      _selectionDate = null;
    });
  }

  void _showDatePicker() {
    setState(() => _isDatePickerVisible = true);
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
              provider.copyFromYesterday(mode: ApplyTemplateMode.fillEmptyOnly);
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
                          separatorBuilder: (_, __) => const Divider(height: 1),
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

  void _showSaveTemplateDialog(TimeProvider provider, {VoidCallback? onSaved}) {
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
    ).whenComplete(() => nameController.dispose());
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
    ).whenComplete(() => nameController.dispose());
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

/// Windows 双列布局中单个日期列：自持拖选/高亮状态，并与共享时间轴联动滚动。
/// Windows 三列视图下的单列日期头：显示日期 + 星期，今天的列高亮。
class _DayHeader extends StatelessWidget {
  final DateTime date;

  const _DayHeader({required this.date});

  bool get _isToday {
    final now = DateTime.now();
    return now.year == date.year && now.month == date.month && now.day == date.day;
  }

  @override
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
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _DayGrid extends StatefulWidget {
  final DateTime date;
  final ScrollController timeAxisController;
  final void Function(DateTime date, int startIndex, int endIndex)
      onSelectionChanged;
  final void Function(DateTime date, int index) onRemoveSlot;

  const _DayGrid({
    required this.date,
    required this.timeAxisController,
    required this.onSelectionChanged,
    required this.onRemoveSlot,
  });

  @override
  State<_DayGrid> createState() => _DayGridState();
}

class _DayGridState extends State<_DayGrid> {
  final GlobalKey _gridKey = GlobalKey();
  final ScrollController _gridScrollController = ScrollController();
  int? _dragStartIndex;
  int? _dragEndIndex;

  @override
  void initState() {
    super.initState();
    // 共享时间轴滚动时保持网格对齐
    widget.timeAxisController.addListener(_syncFromTimeAxis);
    // 首帧定位到共享时间轴当前位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_gridScrollController.hasClients) {
        _gridScrollController.jumpTo(widget.timeAxisController.offset);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _DayGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeAxisController != widget.timeAxisController) {
      oldWidget.timeAxisController.removeListener(_syncFromTimeAxis);
      widget.timeAxisController.addListener(_syncFromTimeAxis);
    }
    if (oldWidget.date != widget.date) {
      // 日期变化时重置拖选并保持与时间轴对齐
      setState(() {
        _dragStartIndex = null;
        _dragEndIndex = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_gridScrollController.hasClients) {
          _gridScrollController.jumpTo(widget.timeAxisController.offset);
        }
      });
    }
  }

  @override
  void dispose() {
    widget.timeAxisController.removeListener(_syncFromTimeAxis);
    _gridScrollController.dispose();
    super.dispose();
  }

  void _syncFromTimeAxis() {
    if (!_gridScrollController.hasClients) return;
    final target = widget.timeAxisController.offset;
    if ((_gridScrollController.offset - target).abs() > 0.5) {
      _gridScrollController.jumpTo(target);
    }
  }

  int _calculateIndex(Offset globalPosition) {
    final RenderBox? box =
        _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return 0;

    final Offset localOffset = box.globalToLocal(globalPosition);
    final double adjustedDy = localOffset.dy + widget.timeAxisController.offset;

    double topPadding = 8.0;
    int row = ((adjustedDy - topPadding) / 45).floor().clamp(0, 23);

    double gridWidth = box.size.width;
    int col = (localOffset.dx / (gridWidth / 6)).floor().clamp(0, 5);

    return row * 6 + col;
  }

  void _handleSelect(Offset globalPosition,
      {bool isClick = false, bool isStart = false}) {
    final currentIndex = _calculateIndex(globalPosition);

    setState(() {
      if (isClick) {
        // 点击已选中的格子则取消选择
        if (_dragStartIndex == currentIndex && _dragEndIndex == currentIndex) {
          _dragStartIndex = null;
          _dragEndIndex = null;
        } else {
          _dragStartIndex = currentIndex;
          _dragEndIndex = currentIndex;
        }
      } else {
        if (isStart) {
          _dragStartIndex = currentIndex;
        }
        _dragEndIndex = currentIndex;
      }
    });

    if (_dragStartIndex != null && _dragEndIndex != null) {
      widget.onSelectionChanged(widget.date, _dragStartIndex!, _dragEndIndex!);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 网格自身不可滚动（时间轴驱动），鼠标滚轮事件由监听器转发给共享时间轴，
    // 从而光标停留在网格上时也能上下滚动（安卓无滚轮事件，不受影响）。
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final axis = widget.timeAxisController;
          if (axis.hasClients) {
            axis.position.pointerScroll(event.scrollDelta.dy);
          }
        }
      },
      child: TimeGrid(
        gridKey: _gridKey,
        date: widget.date,
        controller: _gridScrollController,
        dragStartIndex: _dragStartIndex,
        dragEndIndex: _dragEndIndex,
        onTapDown: (position) => _handleSelect(position, isClick: true),
        onPanStart: (position) => _handleSelect(position, isStart: true),
        onPanUpdate: (position) => _handleSelect(position),
        onRemoveSlot: (index) => widget.onRemoveSlot(widget.date, index),
      ),
    );
  }
}

/// 展开/折叠按钮，通过记录按下位置过滤拖动手势
class _ExpandButton extends StatefulWidget {
  final bool isExpanded;
  final VoidCallback onTap;

  const _ExpandButton({required this.isExpanded, required this.onTap});

  @override
  State<_ExpandButton> createState() => _ExpandButtonState();
}

class _ExpandButtonState extends State<_ExpandButton> {
  Offset? _downPosition;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _downPosition = event.position,
      onPointerUp: (event) {
        if (_downPosition != null) {
          final distance = (event.position - _downPosition!).distance;
          if (distance < 10.0) {
            widget.onTap();
          }
        }
        _downPosition = null;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Icon(
          widget.isExpanded ? Icons.expand_less : Icons.expand_more,
          color: Colors.white,
          size: 16,
        ),
      ),
    );
  }
}

/// 可排序的 Chip Wrap 组件
/// 支持自动换行 + 拖动排序动画
class _ReorderableChipWrap extends StatefulWidget {
  final List<String> items;
  final Color color;
  final Function(int oldIndex, int newIndex) onReorder;
  final Function(String item, int index) onTap;

  const _ReorderableChipWrap({
    required this.items,
    required this.color,
    required this.onReorder,
    required this.onTap,
  });

  @override
  State<_ReorderableChipWrap> createState() => _ReorderableChipWrapState();
}

class _ReorderableChipWrapState extends State<_ReorderableChipWrap> {
  int? _draggedIndex;
  final GlobalKey _wrapKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: _wrapKey,
      spacing: 8.0,
      runSpacing: 8.0,
      children: widget.items.asMap().entries.map((entry) {
        final index = entry.key;
        final item = entry.value;

        return LongPressDraggable<String>(
          data: item,
          delay: const Duration(milliseconds: 300),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            elevation: 8.0,
            borderRadius: BorderRadius.circular(8),
            child: Chip(
              visualDensity: VisualDensity.compact,
              backgroundColor: widget.color,
              label: Text(item,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              side: BorderSide.none,
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.2,
            child: _buildChip(item, index),
          ),
          onDragStarted: () {
            setState(() {
              _draggedIndex = index;
            });
          },
          onDragUpdate: (details) {
            if (_draggedIndex == null ||
                _draggedIndex! >= widget.items.length) return;
            final renderBox =
                _wrapKey.currentContext?.findRenderObject() as RenderBox?;
            if (renderBox == null) return;
            final localPos = renderBox.globalToLocal(details.globalPosition);
            final newIndex = _getItemIndexAtPosition(localPos);
            if (newIndex != null && newIndex != _draggedIndex) {
              final oldIndex = _draggedIndex!;
              widget.onReorder(oldIndex, newIndex);
              setState(() {
                _draggedIndex = newIndex;
              });
            }
          },
          onDragEnd: (details) {
            setState(() {
              _draggedIndex = null;
            });
          },
          child: _buildChip(item, index),
        );
      }).toList(),
    );
  }

  Widget _buildChip(String item, int index) {
    return GestureDetector(
      onTap: () => widget.onTap(item, index),
      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.color.withValues(alpha: 0.8),
        label: Text(item,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),
    );
  }

  int? _getItemIndexAtPosition(Offset position) {
    final wrap = _wrapKey.currentContext?.findRenderObject();
    if (wrap == null) return null;

    final box = wrap as RenderBox;
    final wrapSize = box.size;

    // 根据位置估算索引
    const chipWidth = 88.0;
    const chipHeight = 40.0;

    final col = (position.dx / chipWidth).floor();
    final row = (position.dy / chipHeight).floor();
    final index = row * (wrapSize.width ~/ chipWidth) + col;

    if (index >= 0 && index < widget.items.length) {
      return index;
    }
    return null;
  }
}
