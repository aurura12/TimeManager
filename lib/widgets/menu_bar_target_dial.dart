import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/category.dart';
import '../providers/time_provider.dart';
import '../services/menu_bar_target_store.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/motion.dart';

/// 相机拨轮式的分类 / 子事件选择器。
///
/// 左右两个竖向转盘：左边分类、右边当前分类的子事件（第 0 项「整个分类」）。
/// 中间是固定选中框，项从框里滑过；鼠标滚轮在哪个盘上就转哪个。
///
/// 写入规则：
/// - 转子事件盘停下 → 写入「分类 + 子事件」；
/// - 转分类盘到一个没有子事件的分类 → 停下写入该分类；
/// - 转分类盘到一个有子事件的分类 → 不写，等用户继续转子事件；
/// - 点任意一个盘的中间项 → 立即写入当前组合。
class MenuBarTargetDial extends StatefulWidget {
  const MenuBarTargetDial({
    super.key,
    required this.categories,
    required this.onWrite,
    this.initialTarget,
    this.enabled = true,
  });

  final List<Category> categories;
  final MenuBarTarget? initialTarget;
  final bool enabled;
  final void Function(Category category, String? subLabel) onWrite;

  static const Key categoryWheelKey = ValueKey('menu-bar-dial-category');
  static const Key subWheelKey = ValueKey('menu-bar-dial-sub');

  static const String wholeCategoryLabel = '整个分类';
  static const Duration settleDelay = Duration(milliseconds: 800);

  static double get height => AppSizes.dialRowHeight * AppSizes.dialVisibleRows;

  @override
  State<MenuBarTargetDial> createState() => _MenuBarTargetDialState();
}

class _MenuBarTargetDialState extends State<MenuBarTargetDial> {
  late final FixedExtentScrollController _categoryController;
  final Map<String, FixedExtentScrollController> _subControllers =
      <String, FixedExtentScrollController>{};
  final Map<String, int> _subMemory = <String, int>{};

  late int _categoryIndex;
  late int _subIndex;
  Timer? _settleTimer;
  bool _didWrite = false;

  @override
  void initState() {
    super.initState();
    _categoryIndex = _resolveCategoryIndex();
    _subIndex = _initialSubIndexFor(_currentCategory);
    _categoryController =
        FixedExtentScrollController(initialItem: _categoryIndex);
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _categoryController.dispose();
    for (final controller in _subControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Category? get _currentCategory {
    final categories = widget.categories;
    if (categories.isEmpty) return null;
    return categories[_categoryIndex.clamp(0, categories.length - 1)];
  }

  List<String?> _subItemsOf(Category category) =>
      <String?>[null, ...category.subCategories];

  int _resolveCategoryIndex() {
    final target = widget.initialTarget;
    if (target != null && widget.categories.isNotEmpty) {
      final byId = widget.categories
          .indexWhere((category) => category.id == target.categoryId);
      if (byId >= 0) return byId;
      final name = target.categoryName;
      if (name != null) {
        final byName =
            widget.categories.indexWhere((category) => category.name == name);
        if (byName >= 0) return byName;
      }
    }
    // 没有记住的目标时跳过本机的「临时」：它只用于随手命名，
    // 默认落在真实分类上更安全。全是临时分类时才回 0。
    final fallback = widget.categories.indexWhere(
      (category) => category.name != TimeProvider.temporaryCategoryName,
    );
    return fallback < 0 ? 0 : fallback;
  }

  int _initialSubIndexFor(Category? category) {
    if (category == null) return 0;
    final sub = widget.initialTarget?.subLabel;
    if (sub == null) return 0;
    final index = _subItemsOf(category).indexOf(sub);
    return index < 0 ? 0 : index;
  }

  FixedExtentScrollController _subControllerFor(Category category) {
    return _subControllers.putIfAbsent(category.id, () {
      final initial = _subMemory[category.id] ?? _initialSubIndexFor(category);
      return FixedExtentScrollController(initialItem: initial);
    });
  }

  String? _subLabelFor(Category category) {
    if (category.subCategories.isEmpty) return null;
    final items = _subItemsOf(category);
    return items[_subIndex.clamp(0, items.length - 1)];
  }

  void _cancelSettle() {
    _settleTimer?.cancel();
    _settleTimer = null;
  }

  void _scheduleSettle() {
    _cancelSettle();
    if (!widget.enabled || _didWrite) return;
    _settleTimer = Timer(MenuBarTargetDial.settleDelay, _commit);
  }

  void _commit() {
    _cancelSettle();
    if (!mounted || !widget.enabled || _didWrite) return;
    final category = _currentCategory;
    if (category == null) return;
    _didWrite = true;
    widget.onWrite(category, _subLabelFor(category));
  }

  void _onCategoryChanged(int index) {
    if (index == _categoryIndex || index >= widget.categories.length) return;
    final category = widget.categories[index];
    setState(() {
      _categoryIndex = index;
      _subIndex = _subMemory[category.id] ?? 0;
    });
    // 有子事件时不要立刻写：右盘刚重置到「整个分类」，等用户选完子事件。
    if (category.subCategories.isEmpty) {
      _scheduleSettle();
    } else {
      _cancelSettle();
    }
  }

  void _onSubChanged(int index) {
    final category = _currentCategory;
    if (category == null || index == _subIndex) return;
    setState(() {
      _subIndex = index;
      _subMemory[category.id] = index;
    });
    _scheduleSettle();
  }

  void _tapCategory(int index) {
    if (!widget.enabled) return;
    if (index != _categoryIndex) {
      _categoryController.animateToItem(
        index,
        duration: appMotionDuration(context),
        curve: AppMotion.curve,
      );
      return;
    }
    _commit();
  }

  void _tapSub(int index) {
    if (!widget.enabled) return;
    final category = _currentCategory;
    if (category == null) return;
    final controller = _subControllerFor(category);
    if (index != _subIndex) {
      controller.animateToItem(
        index,
        duration: appMotionDuration(context),
        curve: AppMotion.curve,
      );
      return;
    }
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.categories;
    if (categories.isEmpty) {
      return SizedBox(
        height: MenuBarTargetDial.height,
        child: Center(
          child: Text(
            '还没有分类，请先在主窗口里添加',
            style: AppText.caption.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      );
    }

    final category = _currentCategory!;
    final subItems = _subItemsOf(category);
    final behavior = ScrollConfiguration.of(context);

    return ScrollConfiguration(
      behavior: behavior.copyWith(
        scrollbars: false,
        dragDevices: <PointerDeviceKind>{
          ...behavior.dragDevices,
          PointerDeviceKind.mouse,
        },
      ),
      child: SizedBox(
        height: MenuBarTargetDial.height,
        child: Row(
          children: [
            Expanded(
              child: _buildWheel(
                context,
                wheelKey: MenuBarTargetDial.categoryWheelKey,
                controller: _categoryController,
                itemCount: categories.length,
                labelOf: (index) => categories[index].name,
                colorOf: (index) => categories[index].color,
                selectedIndex: _categoryIndex,
                onSelected: _onCategoryChanged,
                onTap: _tapCategory,
              ),
            ),
            const SizedBox(width: AppSizes.dialColumnGap),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey<String>('dial-sub-${category.id}'),
                child: _buildWheel(
                  context,
                  wheelKey: MenuBarTargetDial.subWheelKey,
                  controller: _subControllerFor(category),
                  itemCount: subItems.length,
                  labelOf: (index) =>
                      subItems[index] ?? MenuBarTargetDial.wholeCategoryLabel,
                  colorOf: (_) => category.color,
                  selectedIndex: _subIndex,
                  onSelected: _onSubChanged,
                  onTap: _tapSub,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWheel(
    BuildContext context, {
    required Key wheelKey,
    required FixedExtentScrollController controller,
    required int itemCount,
    required String Function(int index) labelOf,
    required Color Function(int index) colorOf,
    required int selectedIndex,
    required ValueChanged<int> onSelected,
    required ValueChanged<int> onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: Container(
              height: AppSizes.dialRowHeight - AppSpacing.xs,
              margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              decoration: BoxDecoration(
                color: surfaces.subtle,
                borderRadius: AppRadius.controlAll,
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.35),
                  width: AppSizes.border,
                ),
              ),
            ),
          ),
          ListWheelScrollView.useDelegate(
            key: wheelKey,
            controller: controller,
            itemExtent: AppSizes.dialRowHeight,
            overAndUnderCenterOpacity: 0.35,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: onSelected,
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: itemCount,
              builder: (context, index) => _buildItem(
                context,
                label: labelOf(index),
                color: colorOf(index),
                selected: index == selectedIndex,
                onTap: () => onTap(index),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(
    BuildContext context, {
    required String label,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? onTap : null,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                backgroundColor: color,
                radius: AppSizes.statusDot,
              ),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}