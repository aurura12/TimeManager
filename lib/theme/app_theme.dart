import 'package:flutter/material.dart';

import 'app_semantic_colors.dart';
import 'app_tokens.dart';

/// 表面层级扩展。
///
/// 页面不要再写 `isDark ? a : b` 来选底色 —— 从 `AppSurfaces.of(context)`
/// 取语义化的表面色即可，浅色/深色由主题一次性给定。
@immutable
class AppSurfaces extends ThemeExtension<AppSurfaces> {
  const AppSurfaces({
    required this.page,
    required this.card,
    required this.panel,
    required this.subtle,
    required this.gridEmpty,
    required this.border,
    required this.navSelected,
    required this.joinDivider,
  });

  /// 页面背景（最底层）
  final Color page;

  /// 内容面 / 卡片
  final Color card;

  /// 顶部与底部导航、侧栏等"条状"表面
  final Color panel;

  /// 次级底色：输入框填充、未选中 chip、卡片内的分区
  final Color subtle;

  /// 空白时间格
  final Color gridEmpty;

  /// 弱边框
  final Color border;

  /// 导航选中背景
  final Color navSelected;

  /// 网格列之间的分割线
  final Color joinDivider;

  /// 取当前主题的表面色。
  ///
  /// 若主题未注册本扩展（例如测试里裸用 `MaterialApp`），按亮度回退到默认值，
  /// 避免 `!` 抛空。
  static AppSurfaces of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppSurfaces>() ?? forColorScheme(theme.colorScheme);
  }

  static AppSurfaces forColorScheme(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return AppSurfaces(
      page: isDark ? const Color(0xFF111315) : const Color(0xFFF8F9FA),
      card: isDark ? const Color(0xFF1B1F1C) : const Color(0xFFFFFFFF),
      panel: isDark ? const Color(0xFF161A18) : const Color(0xFFFFFFFF),
      subtle: isDark ? const Color(0xFF232725) : const Color(0xFFF1F3F0),
      gridEmpty: isDark ? const Color(0xFF2B312D) : const Color(0xFFE6E9E4),
      border: scheme.outlineVariant,
      navSelected: scheme.primaryContainer,
      joinDivider: isDark ? const Color(0x1AFFFFFF) : const Color(0x1A000000),
    );
  }

  @override
  AppSurfaces copyWith({
    Color? page,
    Color? card,
    Color? panel,
    Color? subtle,
    Color? gridEmpty,
    Color? border,
    Color? navSelected,
    Color? joinDivider,
  }) {
    return AppSurfaces(
      page: page ?? this.page,
      card: card ?? this.card,
      panel: panel ?? this.panel,
      subtle: subtle ?? this.subtle,
      gridEmpty: gridEmpty ?? this.gridEmpty,
      border: border ?? this.border,
      navSelected: navSelected ?? this.navSelected,
      joinDivider: joinDivider ?? this.joinDivider,
    );
  }

  @override
  AppSurfaces lerp(ThemeExtension<AppSurfaces>? other, double t) {
    if (other is! AppSurfaces) return this;
    return AppSurfaces(
      page: Color.lerp(page, other.page, t)!,
      card: Color.lerp(card, other.card, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      subtle: Color.lerp(subtle, other.subtle, t)!,
      gridEmpty: Color.lerp(gridEmpty, other.gridEmpty, t)!,
      border: Color.lerp(border, other.border, t)!,
      navSelected: Color.lerp(navSelected, other.navSelected, t)!,
      joinDivider: Color.lerp(joinDivider, other.joinDivider, t)!,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppSurfaces &&
        other.page == page &&
        other.card == card &&
        other.panel == panel &&
        other.subtle == subtle &&
        other.gridEmpty == gridEmpty &&
        other.border == border &&
        other.navSelected == navSelected &&
        other.joinDivider == joinDivider;
  }

  @override
  int get hashCode => Object.hash(page, card, panel, subtle, gridEmpty, border,
      navSelected, joinDivider);
}

/// 语义实色（分类色 / 目标色 / 身份色 / 奖牌色）在深色模式下的适配。
///
/// 这些颜色属于白名单，**色相不能被主色替换**；但在深色背景上直接铺实色会偏刺眼，
/// 所以统一与内容面混合一档。规则只在这里写一次，页面不再各写一遍 `isDark`。
extension AppSemanticColorAdaptation on BuildContext {
  Color adaptSemanticColor(Color color) {
    final theme = Theme.of(this);
    if (theme.brightness != Brightness.dark) return color;
    return Color.lerp(color, theme.colorScheme.surfaceContainerHigh, 0.45)!;
  }
}

/// 应用主题。
///
/// 职责只有两件事：
/// 1. 由品牌种子色生成 `ColorScheme`，并给出浅色/深色的表面层级；
/// 2. 为所有 Material 组件注册统一的圆角、高度、间距。
///
/// 页面里不要再写 `const Color(0xFF9CB86A)` 之类的品牌色字面量。
abstract final class AppTheme {
  /// 品牌种子色。**唯一**定义处。
  static const Color seedColor = AppSemanticColors.brand;

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  /// 兼容旧调用点（旧 API 是 `AppTheme.light` / `AppTheme.dark` 方法）。
  static ThemeData themeFor(Brightness brightness) => _build(brightness);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    final surfaces = AppSurfaces.forColorScheme(scheme);

    final base = isDark ? ThemeData.dark() : ThemeData.light();
    final textTheme = base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: AppRadius.controlAll,
      borderSide: BorderSide(color: surfaces.border),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: surfaces.page,
      canvasColor: surfaces.page,
      extensions: <ThemeExtension<dynamic>>[surfaces],

      // ---------- 顶部 ----------
      appBarTheme: AppBarThemeData(
        backgroundColor: surfaces.panel,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: AppSizes.appBar,
        titleSpacing: AppSpacing.lg,
        titleTextStyle: AppText.pageTitle.copyWith(color: scheme.onSurface),
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        actionsIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        // 内容面与页面背景很接近，靠一条弱边框拉开层级
        shape: Border(bottom: BorderSide(color: surfaces.border)),
      ),

      // ---------- 导航 ----------
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaces.panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        height: AppSizes.navBar,
        indicatorColor: surfaces.navSelected,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => AppText.badge.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surfaces.panel,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: scheme.onPrimaryContainer,
        unselectedItemColor: scheme.onSurfaceVariant,
        selectedLabelStyle: AppText.badge.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: AppText.badge,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surfaces.panel,
        elevation: 0,
        useIndicator: true,
        indicatorColor: surfaces.navSelected,
        selectedIconTheme:
            IconThemeData(color: scheme.onPrimaryContainer, size: 22),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        selectedLabelTextStyle: AppText.badge.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: AppText.badge.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      // ---------- 卡片与容器 ----------
      cardTheme: CardThemeData(
        color: surfaces.card,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.cardAll,
          side: BorderSide(color: surfaces.border),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: surfaces.border,
        thickness: AppSizes.border,
        space: AppSizes.border,
      ),
      listTileTheme: ListTileThemeData(
        minVerticalPadding: AppSpacing.sm,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        titleTextStyle: AppText.body.copyWith(color: scheme.onSurface),
        subtitleTextStyle: AppText.caption.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.controlAll),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaces.subtle,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: surfaces.border),
        labelStyle: AppText.badge.copyWith(color: scheme.onSurface),
        secondaryLabelStyle:
            AppText.badge.copyWith(color: scheme.onPrimaryContainer),
        padding: AppSpacing.chip,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.badgeAll),
      ),

      // ---------- 按钮 ----------
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppSizes.button),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.controlAll,
          ),
          textStyle: AppText.button,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, AppSizes.button),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          elevation: 0,
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
          disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.controlAll,
          ),
          textStyle: AppText.button,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, AppSizes.button),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: surfaces.border),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.controlAll,
          ),
          textStyle: AppText.button,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          // 规范下限 44；图标按钮的触摸目标由 AppSizes.minTapTarget 保证
          minimumSize: const Size(0, AppSizes.button),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          foregroundColor: scheme.primary,
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.controlAll,
          ),
          textStyle: AppText.button,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          // 触摸目标不小于 44，视觉尺寸由页面自己控制
          minimumSize: const Size(AppSizes.minTapTarget, AppSizes.minTapTarget),
          foregroundColor: scheme.onSurfaceVariant,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize:
              const WidgetStatePropertyAll(Size(0, AppSizes.segmented)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: AppSpacing.md),
          ),
          textStyle: WidgetStatePropertyAll(AppText.caption),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.controlAll),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: surfaces.border)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primaryContainer
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),

      // ---------- 输入 ----------
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: surfaces.subtle,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        constraints: const BoxConstraints(minHeight: AppSizes.input),
        border: inputBorder,
        enabledBorder: inputBorder,
        disabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        hintStyle: AppText.body.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        labelStyle: AppText.body.copyWith(color: scheme.onSurfaceVariant),
        errorStyle: AppText.caption.copyWith(color: scheme.error),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        iconColor: scheme.onSurfaceVariant,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: AppText.body.copyWith(color: scheme.onSurface),
        inputDecorationTheme: InputDecorationThemeData(
          filled: true,
          fillColor: surfaces.subtle,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          border: inputBorder,
          enabledBorder: inputBorder,
          focusedBorder: inputBorder.copyWith(
            borderSide: BorderSide(color: scheme.primary, width: 1.5),
          ),
        ),
      ),

      // ---------- 浮层 ----------
      dialogTheme: DialogThemeData(
        backgroundColor: surfaces.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.xl,
        ),
        titleTextStyle: AppText.sectionTitle.copyWith(color: scheme.onSurface),
        contentTextStyle: AppText.body.copyWith(color: scheme.onSurfaceVariant),
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.sheetAll,
          side: BorderSide(color: surfaces.border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaces.card,
        modalBackgroundColor: surfaces.card,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        dragHandleColor: surfaces.border,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.sheetTop,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaces.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        textStyle: AppText.body.copyWith(color: scheme.onSurface),
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.controlAll,
          side: BorderSide(color: surfaces.border),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            isDark ? scheme.surfaceContainerHighest : scheme.inverseSurface,
        contentTextStyle: AppText.body.copyWith(
          color: isDark ? scheme.onSurface : scheme.onInverseSurface,
        ),
        actionTextColor: scheme.primaryContainer,
        insetPadding: const EdgeInsets.all(AppSpacing.lg),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.controlAll,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color:
              isDark ? scheme.surfaceContainerHighest : scheme.inverseSurface,
          borderRadius: AppRadius.badgeAll,
        ),
        textStyle: AppText.badge.copyWith(
          color: isDark ? scheme.onSurface : scheme.onInverseSurface,
        ),
      ),

      // ---------- 其它控件 ----------
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: surfaces.subtle,
        circularTrackColor: surfaces.subtle,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: surfaces.subtle,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.onPrimary : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.primary : null,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.gridAll),
        side: BorderSide(color: surfaces.border, width: 1.5),
        fillColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.primary : null,
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.primary : null,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: surfaces.border,
        labelStyle: AppText.body.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: AppText.body,
      ),
    );
  }
}
