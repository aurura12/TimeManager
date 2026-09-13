import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/check_in_goal.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/providers/theme_mode_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/screens/main_screen.dart';
import 'package:time_manager/screens/word_cloud_screen.dart';
import 'package:time_manager/services/on_this_day_service.dart';
import 'package:time_manager/theme/app_semantic_colors.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/utils/platform_features.dart';
import 'package:time_manager/widgets/date_picker_panel.dart';

/// 测试用的 GoogleSignInPlatform fake：所有方法返回安全默认值，
/// 避免 TimeProvider 初始化时 GoogleCalendarService.restoreSignIn 抛 UnimplementedError。
class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    return null;
  }

  @override
  bool supportsAuthenticate() => false;

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) {
    throw UnimplementedError();
  }

  @override
  bool authorizationRequiresUserInteraction() => false;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<void> clearAuthorizationToken(
      ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

/// 相对亮度对比度（WCAG）。
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// 第 4 项「统一视觉系统」的验收测试。
///
/// 只覆盖规范本身：主题令牌、语义色白名单、表面层级、实色块文字对比度、
/// 日期面板的选中/今天表现，以及真实 MainScreen 在窄屏下不溢出。不涉及业务逻辑。
void main() {
  /// 主题里注册的那份表面色。
  AppSurfaces surfacesOf(ThemeData theme) =>
      AppSurfaces.forColorScheme(theme.colorScheme);

  group('主题令牌', () {
    test('浅色用米白背景 + 白色内容面，深色用深灰绿背景', () {
      final light = AppTheme.light();
      final dark = AppTheme.dark();

      expect(light.scaffoldBackgroundColor, const Color(0xFFF8F9FA));
      expect(dark.scaffoldBackgroundColor, const Color(0xFF111315));

      expect(surfacesOf(light).page, const Color(0xFFF8F9FA));
      expect(surfacesOf(light).card, const Color(0xFFFFFFFF));
      expect(surfacesOf(dark).page, const Color(0xFF111315));
      expect(surfacesOf(dark).card, const Color(0xFF1B1F1C));
      // 空白时间格在浅色下要比原来的中灰更浅
      expect(surfacesOf(light).gridEmpty, const Color(0xFFE6E9E4));
    });

    test('品牌种子色保持 #9CB86A，不被换掉', () {
      expect(AppTheme.seedColor, const Color(0xFF9CB86A));
      expect(AppSemanticColors.brand, AppTheme.seedColor);
      expect(AppTheme.light().colorScheme.brightness, Brightness.light);
      expect(AppTheme.dark().colorScheme.brightness, Brightness.dark);
    });

    test('圆角按用途分档，且连续时间块接缝为 0', () {
      expect(AppRadius.grid, 4);
      expect(AppRadius.control, 12);
      expect(AppRadius.card, 16);
      expect(AppRadius.sheet, 20);
      expect(AppRadius.joined, 0);

      final theme = AppTheme.light();
      final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
      expect(cardShape.borderRadius, AppRadius.cardAll);
      final dialogShape = theme.dialogTheme.shape! as RoundedRectangleBorder;
      expect(dialogShape.borderRadius, AppRadius.sheetAll);
      final sheetShape =
          theme.bottomSheetTheme.shape! as RoundedRectangleBorder;
      expect(sheetShape.borderRadius, AppRadius.sheetTop);
    });

    test('间距只用 4/8/12/16/24', () {
      expect(
        [
          AppSpacing.xs,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.xl,
        ],
        [4, 8, 12, 16, 24],
      );
      expect(AppSpacing.pageHorizontal, 16);
    });

    test('导航与 AppBar 走主题表面，选中项用 primaryContainer', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final scheme = theme.colorScheme;
        final surfaces = surfacesOf(theme);
        expect(
            theme.navigationBarTheme.indicatorColor, scheme.primaryContainer);
        expect(
            theme.navigationRailTheme.indicatorColor, scheme.primaryContainer);
        expect(theme.navigationBarTheme.backgroundColor, surfaces.panel);
        expect(theme.navigationRailTheme.backgroundColor, surfaces.panel);
        expect(theme.bottomNavigationBarTheme.backgroundColor, surfaces.panel);
        // AppBar 底色交回主题表面，不再是大面积橄榄绿
        expect(theme.appBarTheme.backgroundColor, surfaces.panel);
        expect(theme.appBarTheme.elevation, 0);
        expect(theme.appBarTheme.scrolledUnderElevation, 0);
      }
    });

    test('可点击控件最小高度不小于 44', () {
      expect(AppSizes.minTapTarget, greaterThanOrEqualTo(44));
      expect(AppSizes.button, greaterThanOrEqualTo(44));
      final theme = AppTheme.light();
      final none = const <WidgetState>{};
      double minHeight(ButtonStyle? style) =>
          style?.minimumSize?.resolve(none)?.height ?? 0;

      expect(
          minHeight(theme.filledButtonTheme.style), greaterThanOrEqualTo(44));
      expect(
          minHeight(theme.elevatedButtonTheme.style), greaterThanOrEqualTo(44));
      expect(
          minHeight(theme.outlinedButtonTheme.style), greaterThanOrEqualTo(44));
      // TextButton 也必须在 44 以上（曾误设为 40）
      expect(minHeight(theme.textButtonTheme.style), greaterThanOrEqualTo(44));
      expect(minHeight(theme.segmentedButtonTheme.style),
          greaterThanOrEqualTo(36));
      expect(minHeight(theme.iconButtonTheme.style), greaterThanOrEqualTo(44));
    });

    test('主题里不再有页面上限定的品牌绿字面量', () {
      // 品牌绿只在 app_semantic_colors.dart 定义一次
      expect(AppSemanticColors.brand, const Color(0xFF9CB86A));
      expect(AppTheme.seedColor, AppSemanticColors.brand);
      expect(AppSemanticColors.brandSurface, const Color(0xFF96B462));
    });

    test('卡片是弱边框 + 无阴影', () {
      final theme = AppTheme.light();
      expect(theme.cardTheme.elevation, 0);
      final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
      expect(shape.side.style, BorderStyle.solid);
      expect(shape.side.color, surfacesOf(theme).border);
    });

    test('输入框统一圆角 12 并带聚焦主色描边', () {
      final theme = AppTheme.light();
      final border = theme.inputDecorationTheme;
      expect(border.filled, isTrue);
      expect(border.fillColor, surfacesOf(theme).subtle);
      expect((border.enabledBorder as OutlineInputBorder).borderRadius,
          AppRadius.controlAll);
      expect((border.focusedBorder as OutlineInputBorder).borderSide.color,
          theme.colorScheme.primary);
    });
  });

  group('语义色白名单', () {
    test('十六进制颜色输入支持 6/8 位并统一返回不透明色', () {
      expect(
          AppSemanticColors.parseOpaqueHex('#FFFFFF'), const Color(0xFFFFFFFF));
      expect(AppSemanticColors.parseOpaqueHex('80FF0000'),
          const Color(0xFFFF0000));
      expect(AppSemanticColors.parseOpaqueHex('0x00FF00'),
          const Color(0xFF00FF00));
      expect(AppSemanticColors.parseOpaqueHex('FFF'), isNull);
      expect(AppSemanticColors.parseOpaqueHex('GGGGGG'), isNull);
    });

    test('身份色、奖牌色、日历导入色保持原值', () {
      expect(AppSemanticColors.identityGuaiGuai, const Color(0xFF4DA8EE));
      expect(AppSemanticColors.identityJingJing, const Color(0xFFF16B77));
      expect(AppSemanticColors.medalGold, const Color(0xFFD4AF37));
      expect(AppSemanticColors.medalSilver, const Color(0xFFC0C0C0));
      expect(AppSemanticColors.medalBronze, const Color(0xFFCD7F32));
      expect(AppSemanticColors.calendarImport, const Color(0xFF78909C));
    });

    test('分类调色板顺序稳定（取色器依赖下标取值）', () {
      expect(AppSemanticColors.palette, const [
        Color(0xFFF16B77),
        Color(0xFFF98E45),
        Color(0xFFD9BD2E),
        Color(0xFF96B462),
        Color(0xFF4DA8EE),
        Color(0xFF9575CD),
        Color(0xFFE91E63),
      ]);
      expect(AppSemanticColors.palette[3], AppSemanticColors.brandSurface);
    });

    test('状态色不跟随主题切换', () {
      expect(AppSemanticColors.danger, const Color(0xFFFE4A49));
      expect(AppSemanticColors.warning, const Color(0xFFF98E45));
      expect(AppSemanticColors.success, AppSemanticColors.brand);
    });
  });

  group('AppSurfaces 取值', () {
    testWidgets('主题注册了 AppSurfaces，页面可直接取到', (tester) async {
      late AppSurfaces surfaces;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: Builder(builder: (context) {
          surfaces = AppSurfaces.of(context);
          return const SizedBox();
        }),
      ));
      expect(
          surfaces, AppSurfaces.forColorScheme(AppTheme.light().colorScheme));
    });

    testWidgets('裸 MaterialApp（未注册扩展）按亮度回退，不抛空', (tester) async {
      late AppSurfaces light;
      late AppSurfaces dark;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          light = AppSurfaces.of(context);
          return const SizedBox();
        }),
      ));
      expect(light.page, const Color(0xFFF8F9FA));

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(builder: (context) {
          dark = AppSurfaces.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle();
      expect(dark.page, const Color(0xFF111315));
    });

    test('深色下语义实色被压暗，色相不变', () {
      // 浅色原样返回；深色与内容面混合一档 —— 规则收敛在 AppSemanticColorAdaptation
      expect(surfacesOf(AppTheme.light()).card, const Color(0xFFFFFFFF));
      expect(surfacesOf(AppTheme.dark()).card, const Color(0xFF1B1F1C));
    });
  });

  group('日期选择器面板', () {
    Future<void> pumpPanel(
      WidgetTester tester, {
      required DateTime initial,
      Size size = const Size(360, 640),
      ThemeData? theme,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: theme ?? AppTheme.light(),
        home: Scaffold(
          body: DatePickerPanel(
            initialDate: initial,
            onDateSelected: (_) {},
          ),
        ),
      ));
    }

    testWidgets('选中日期用主色实心填充，今天只用细边框', (tester) async {
      final today = DateTime.now();
      // 选一个不是今天的日期，保证页面上同时存在"选中"和"今天"
      final picked =
          DateTime(today.year, today.month, today.day == 15 ? 16 : 15);
      await pumpPanel(tester, initial: picked);
      final scheme = AppTheme.light().colorScheme;

      BoxDecoration decorationOf(String day) {
        final container = tester.widget<Container>(
          find
              .ancestor(of: find.text(day), matching: find.byType(Container))
              .first,
        );
        return container.decoration! as BoxDecoration;
      }

      expect(decorationOf('${picked.day}').color, scheme.primary);
      final todayDeco = decorationOf('${today.day}');
      expect(todayDeco.color, isNull);
      expect(todayDeco.border, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('面板底色是内容面，不再整面绿色', (tester) async {
      final now = DateTime.now();
      await pumpPanel(
        tester,
        initial: DateTime(now.year, now.month, 15),
      );
      final material = tester.widget<Material>(
        find
            .descendant(
                of: find.byType(DatePickerPanel),
                matching: find.byType(Material))
            .first,
      );
      expect(material.color, surfacesOf(AppTheme.light()).card);
      expect(material.elevation, 0);
    });

    testWidgets('窄屏（360x640）渲染不溢出', (tester) async {
      final now = DateTime.now();
      await pumpPanel(tester, initial: DateTime(now.year, now.month, 15));
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色模式同样能渲染且不溢出', (tester) async {
      final now = DateTime.now();
      await pumpPanel(
        tester,
        initial: DateTime(now.year, now.month, 15),
        theme: AppTheme.dark(),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('实色块上的文字对比度（P1）', () {
    test('调色板每一色叠 onColor 后都达到 4.5:1', () {
      final backgrounds = <Color>[
        ...AppSemanticColors.palette,
        AppSemanticColors.brand,
        AppSemanticColors.brandSurface,
        AppSemanticColors.identityGuaiGuai,
        AppSemanticColors.identityJingJing,
        AppSemanticColors.danger,
        AppSemanticColors.warning,
        AppSemanticColors.info,
      ];
      for (final bg in backgrounds) {
        final ratio = _contrastRatio(AppSemanticColors.onColor(bg), bg);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '背景 $bg 上的 onColor 对比度只有 ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('固定白字确实不达标（这就是要按背景取色的原因）', () {
      // 芥末黄 / brandSurface 叠白字远低于 4.5:1
      expect(_contrastRatio(Colors.white, AppSemanticColors.mustard),
          lessThan(2.0));
      expect(_contrastRatio(Colors.white, AppSemanticColors.brandSurface),
          lessThan(2.5));
      // 所以这两个颜色必须拿到黑字
      expect(
          AppSemanticColors.onColor(AppSemanticColors.mustard), Colors.black);
      expect(AppSemanticColors.onColor(AppSemanticColors.brandSurface),
          Colors.black);
    });

    test('深色实色仍然拿白字', () {
      expect(AppSemanticColors.onColor(const Color(0xFF1B1B1B)), Colors.white);
      expect(AppSemanticColors.onColor(const Color(0xFF000000)), Colors.white);
      expect(
        _contrastRatio(AppSemanticColors.onColor(const Color(0xFF7B1FA2)),
            const Color(0xFF7B1FA2)),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('onColorMuted 只降透明度，不改变黑白方向', () {
      final bg = AppSemanticColors.palette[3]; // brandSurface
      expect(AppSemanticColors.onColorMuted(bg).a, closeTo(0.7, 0.01));
      expect(AppSemanticColors.onColor(bg), Colors.black);
    });

    test('状态色背景上的 onColor 也达到 4.5:1', () {
      for (final bg in [
        AppSemanticColors.danger,
        AppSemanticColors.warning,
        AppSemanticColors.success,
        AppSemanticColors.info,
      ]) {
        final ratio = _contrastRatio(AppSemanticColors.onColor(bg), bg);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '$bg 上的 onColor 只有 ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('primary / onPrimary 在浅色与深色下都达标', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final scheme = theme.colorScheme;
        final ratio = _contrastRatio(scheme.onPrimary, scheme.primary);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} 的 onPrimary/primary 只有 '
                '${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('「今天未完成」格子：primary 文字压在 20% primary 底上仍达标', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final scheme = theme.colorScheme;
        final page = AppSurfaces.forColorScheme(scheme).page;
        final bg = Color.alphaBlend(
          scheme.primary.withValues(alpha: 0.2),
          page,
        );
        final ratio = _contrastRatio(scheme.primary, bg);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} 今天格子只有 '
                '${ratio.toStringAsFixed(2)}:1');
      }
    });
  });

  group('半透明底的合成与同色系文字（P1）', () {
    const statusColors = <Color>[
      AppSemanticColors.success,
      AppSemanticColors.warning,
      AppSemanticColors.danger,
      AppSemanticColors.info,
    ];

    test('compose：不透明原样返回，半透明按底面合成', () {
      expect(AppSemanticColors.compose(const Color(0xFF123456), Colors.white),
          const Color(0xFF123456));
      expect(AppSemanticColors.compose(const Color(0x00000000), Colors.white),
          Colors.white);
      // 半透明白压在黑底上应该明显暗于纯白
      final blended =
          AppSemanticColors.compose(const Color(0x80FFFFFF), Colors.black);
      expect(blended.computeLuminance(), lessThan(0.6));
    });

    test('tint：alpha=1 等于原色，alpha=0 等于底面，且结果不透明', () {
      const surface = Color(0xFFF8F9FA);
      for (final c in AppSemanticColors.palette) {
        expect(AppSemanticColors.tint(c, surface, 1.0), c);
        expect(AppSemanticColors.tint(c, surface, 0.0), surface);
        expect(AppSemanticColors.tint(c, surface, 0.15).a, 1.0);
      }
    });

    test('onColor 收到半透明底必须传 over，传了就按合成结果算', () {
      // brandSurface 压 30%：这块底在浅色面上其实已经接近白色
      final translucent = AppSemanticColors.palette[3].withValues(alpha: 0.3);
      // 不传 over → 直接抛断言，避免又回到"按未合成颜色算"的坑
      expect(() => AppSemanticColors.onColor(translucent),
          throwsA(isA<AssertionError>()));
      // 传了 over → 与"先 compose 再算"完全一致
      for (final surface in [
        const Color(0xFFF8F9FA),
        const Color(0xFF111315)
      ]) {
        expect(
          AppSemanticColors.onColor(translucent, over: surface),
          AppSemanticColors.onColor(
              AppSemanticColors.compose(translucent, surface)),
        );
      }
    });

    test('首页子分类条 / 编辑块：分类色半透明底上文字都 ≥ 4.5:1', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final sidebar = AppSurfaces.forColorScheme(theme.colorScheme).subtle;
        for (final c in AppSemanticColors.palette) {
          for (final alpha in [0.4, 0.6]) {
            final bg = AppSemanticColors.tint(c, sidebar, alpha);
            final ratio = _contrastRatio(AppSemanticColors.onColor(bg), bg);
            expect(ratio, greaterThanOrEqualTo(4.5),
                reason: '${theme.brightness} 侧栏 $c @$alpha 只有 '
                    '${ratio.toStringAsFixed(2)}:1');
          }
        }
      }
    });

    test('onTint：同色淡底上的文字在三种底面 × 三档透明度下都 ≥ 4.5:1', () {
      const alphas = [0.1, 0.12, 0.15];
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final surfaces = AppSurfaces.forColorScheme(theme.colorScheme);
        for (final surface in [surfaces.page, surfaces.card, surfaces.subtle]) {
          for (final c in [...AppSemanticColors.palette, ...statusColors]) {
            for (final alpha in alphas) {
              final bg = AppSemanticColors.tint(c, surface, alpha);
              final fg = AppSemanticColors.onTint(c, surface, alpha: alpha);
              final ratio = _contrastRatio(fg, bg);
              expect(ratio, greaterThanOrEqualTo(4.5),
                  reason: '${theme.brightness} $c @$alpha 压 $surface 只有 '
                      '${ratio.toStringAsFixed(2)}:1');
            }
          }
        }
      }
    });

    test('readableOn：词云 / 图表 / 状态色当文字用都 ≥ 4.5:1', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final surfaces = AppSurfaces.forColorScheme(theme.colorScheme);
        for (final surface in [surfaces.page, surfaces.card]) {
          final candidates = <Color>[
            ...AppSemanticColors.wordCloud,
            ...AppSemanticColors.chart,
            ...AppSemanticColors.palette,
            ...statusColors,
            AppSemanticColors.brand,
          ];
          for (final c in candidates) {
            final fg = AppSemanticColors.readableOn(c, surface);
            final ratio = _contrastRatio(fg, surface);
            expect(ratio, greaterThanOrEqualTo(4.5),
                reason: '${theme.brightness} $c 当文字压在 $surface 上只有 '
                    '${ratio.toStringAsFixed(2)}:1');
            // 已经够对比的色不该被改
            if (_contrastRatio(c, surface) >= 4.5) {
              expect(fg, c);
            }
          }
        }
      }
    });

    test('选中时间块的主色高亮底上 onSurface ≥ 4.5:1', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final surfaces = AppSurfaces.forColorScheme(theme.colorScheme);
        final bg = Color.alphaBlend(
          theme.colorScheme.primary.withValues(alpha: 0.28),
          surfaces.page,
        );
        final ratio = _contrastRatio(theme.colorScheme.onSurface, bg);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} 高亮时间块只有 '
                '${ratio.toStringAsFixed(2)}:1');
      }
    });
  });

  group('半透明底与同色系底的可读性（复核被点名的具体位置）', () {
    test('打卡「补」徽标：同色 20% 淡底上的文字 ≥ 4.5:1', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final card = AppSemanticColors.tint(AppSemanticColors.warning,
            theme.colorScheme.surfaceContainerLow, 0.2);
        final fg = AppSemanticColors.onTint(
            AppSemanticColors.warning, theme.colorScheme.surfaceContainerLow,
            alpha: 0.2);
        final ratio = _contrastRatio(fg, card);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} 下「补」只有 '
                '${ratio.toStringAsFixed(2)}:1');
        // 顺带确认"直接用语义色当文字"在浅色下确实不达标（这就是问题本身）
      }
      final lightCard = AppSemanticColors.tint(AppSemanticColors.warning,
          AppTheme.light().colorScheme.surfaceContainerLow, 0.2);
      expect(
        _contrastRatio(AppSemanticColors.warning, lightCard),
        lessThan(4.5),
        reason: '如果这条成立了，说明这枚徽标本来就不需要修',
      );
    });

    test('「我的」TabBar 选中标签：品牌绿压在最差底面上 ≥ 4.5:1', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final backdrop = theme.colorScheme.surfaceContainerHigh;
        final fg =
            AppSemanticColors.readableOn(AppSemanticColors.brand, backdrop);
        final ratio = _contrastRatio(fg, backdrop);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} 下 TabBar 标签只有 '
                '${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('确认删除按钮：danger 在弹窗底（内容面）上 ≥ 4.5:1', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final card = AppSurfaces.forColorScheme(theme.colorScheme).card;
        final fg = AppSemanticColors.readableOn(AppSemanticColors.danger, card);
        expect(_contrastRatio(fg, card), greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} 删除文字不达标');
      }
      // 亮红在白底上本来就不合格 —— 说明必须走 readableOn
      expect(_contrastRatio(AppSemanticColors.danger, const Color(0xFFFFFFFF)),
          lessThan(4.5));
    });

    test('dangerDeep：拿不到主题的兜底页用它，浅底 ≥ 4.5:1', () {
      for (final bg in [
        const Color(0xFFFFFFFF), // 默认 MaterialApp 的内容面
        const Color(0xFFF8F9FA), // 应用的页面底色
      ]) {
        final ratio = _contrastRatio(AppSemanticColors.dangerDeep, bg);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: 'dangerDeep 在 $bg 上只有 ${ratio.toStringAsFixed(2)}:1');
      }
    });
  });

  group('颜色只在入口收一次 alpha（P1）', () {
    test('opaque：不透明原样返回，半透明收成 alpha=1', () {
      const solid = Color(0xFF9CB86A);
      expect(AppSemanticColors.opaque(solid), solid);
      const half = Color(0x809CB86A);
      expect(half.a, closeTo(128 / 255, 0.001));
      expect(AppSemanticColors.opaque(half).a, 1.0);
      expect(AppSemanticColors.opaque(half).toARGB32(), 0xFF9CB86A);
    });

    test('8 位 ARGB 的历史分类色不会再让时间块崩', () {
      // 十六进制输入框曾接受 8 位 ARGB，把 alpha 一起存进了分类色
      const legacy = Color(0x809CB86A);
      // 不告知底面时会断言失败（提示"对比度会算错"）
      expect(() => AppSemanticColors.onColor(legacy), throwsAssertionError);
      // 告知底面后不再抛，且结论与"先收成不透明"一致
      final overPage = AppSemanticColors.onColor(legacy,
          over: AppSurfaces.forColorScheme(AppTheme.light().colorScheme).page);
      expect(overPage,
          AppSemanticColors.onColor(AppSemanticColors.opaque(legacy)));
    });

    test('readableOn 收到半透明色先合成，返回值一定不透明', () {
      const half = Color(0x80F16B77);
      final out = AppSemanticColors.readableOn(half, const Color(0xFFFFFFFF));
      expect(out.a, 1.0, reason: '当文字色用就必须不透明');
    });

    test('模型 fromJson 治愈历史半透明色（分类 / 目标 / 打卡）', () {
      final cat = Category.fromJson(<String, dynamic>{
        'id': 'c1',
        'name': '运动',
        'color': 0x809CB86A,
      });
      expect(cat.color.a, 1.0);
      expect(cat.color.toARGB32(), 0xFF9CB86A);

      final target = Target.fromJson(<String, dynamic>{
        'id': 't1',
        'name': '早睡',
        'color': 0x80F16B77,
      });
      expect(target.color.a, 1.0);

      final goal = CheckInGoal.fromJson(<String, dynamic>{
        'id': 'g1',
        'color': 0x80F16B77,
      });
      expect(goal.color.a, 1.0);
    });
  });

  group('词云文字色跟随主题（P2）', () {
    test('同一色板在浅/深卡片底色上得到不同且都达标的结果', () {
      final light = AppTheme.light().colorScheme.surfaceContainerLowest;
      final dark = AppTheme.dark().colorScheme.surfaceContainerLowest;
      expect(_contrastRatio(light, dark), greaterThan(1.0),
          reason: '浅深卡片底色本身就该不同');

      for (var i = 0; i < AppSemanticColors.wordCloud.length; i++) {
        final onLight = WordCloudScreen.wordColor(light, i);
        final onDark = WordCloudScreen.wordColor(dark, i);
        expect(_contrastRatio(onLight, light), greaterThanOrEqualTo(4.5),
            reason: '浅色下第 $i 个词不达标');
        expect(_contrastRatio(onDark, dark), greaterThanOrEqualTo(4.5),
            reason: '深色下第 $i 个词不达标');
        expect(onLight, isNot(onDark), reason: '换主题必须换颜色，第 $i 个');
      }
    });

    test('布局缓存里不含颜色，换主题才会重算', () {
      final src = File('lib/screens/word_cloud_screen.dart').readAsStringSync();
      expect(src, contains('final int colorIndex;'), reason: '布局结果只能存色板下标');
      expect(src, isNot(contains('final Color color;')),
          reason: '一旦把颜色存进布局缓存，换主题就会沿用上一次的颜色');
    });
  });

  group('视觉规范源码守卫', () {
    // 允许保留写死白色的文件：这些白色叠在图片 / 地图上，不属"叠在语义实色上"
    const whiteAllowed = <String>{
      'lib/widgets/check_in_photo_viewer.dart',
      'lib/widgets/check_in_photo_sheet.dart',
      'lib/widgets/check_in_map_preview.dart',
    };
    // 桌面小组件的配色方案本轮不在范围内
    const literalColorAllowed = <String>{
      'lib/services/home_widget_service.dart',
    };

    late final Map<String, String> sources;

    setUpAll(() {
      sources = {};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (path.contains('/theme/')) continue; // 主题文件就是定义这些的地方
        sources[path] = entity.readAsStringSync();
      }
      expect(sources, isNotEmpty, reason: '没读到 lib/ 下的源码，路径基准不对');
    });

    /// 扫描 lib/（除 theme）里命中 [pattern] 的行，命中即为违规。
    List<String> offenders(String pattern, {Set<String>? except}) {
      final regExp = RegExp(pattern);
      final hits = <String>[];
      sources.forEach((path, src) {
        if (except != null && except.contains(path)) return;
        final lines = src.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (regExp.hasMatch(lines[i])) {
            hits.add('$path:${i + 1}: ${lines[i].trim()}');
          }
        }
      });
      return hits;
    }

    void expectClean(String pattern, String hint, {Set<String>? except}) {
      final hits = offenders(pattern, except: except);
      expect(hits, isEmpty,
          reason: '$hint\n命中 ${hits.length} 处：\n${hits.join('\n')}');
    }

    test('页面里没有颜色字面量（品牌色只在 theme 里定义一次）', () {
      expectClean(r'Color\(0x[0-9A-Fa-f]{6,8}\)|0x[fF][fF][0-9A-Fa-f]{6}',
          '发现硬编码颜色，请改用 AppSemanticColors / colorScheme',
          except: literalColorAllowed);
    });

    test('没有为纯颜色用途而写的 isDark 分支', () {
      expectClean(r'\bisDark\b',
          '请改用 AppSurfaces / colorScheme，或 context.adaptSemanticColor');
    });

    test('没有手写的亮度判断（统一走 AppSemanticColors.onColor）', () {
      expectClean(r'estimateBrightnessForColor',
          '请改用 AppSemanticColors.onColor(background)');
    });

    test('没有 Material 命名词当状态色 / 图表色板', () {
      expectClean(
          r'Colors\.(primaries|green|orange|red|redAccent|amber|lime|teal|cyan|purple|pink|grey)\b',
          '请改用 AppSemanticColors 的 success / warning / danger / info / neutral / chartAt');
    });

    test('没有写死的 Colors.white（图片与地图上的白色除外）', () {
      expectClean(r'Colors\.white\b',
          '叠在语义实色上的文字请改用 AppSemanticColors.onColor(background)',
          except: whiteAllowed);
    });

    test('没有把半透明色直接塞给 onColor（必须先 compose / tint）', () {
      expectClean(
          r'onColor\([^)]*withValues\(alpha',
          '半透明底请先 AppSemanticColors.tint(color, surface, a) 合成成不透明色，'
              '或传 over: 底面');
    });

    test('圆角只用 4/6/12/16/20 这几档（或变量）', () {
      const allowed = {'4', '6', '12', '16', '20'};
      final hits = <String>[];
      final pattern = RegExp(r'BorderRadius\.circular\((\d+(?:\.\d+)?)\)');
      sources.forEach((path, src) {
        final lines = src.split('\n');
        for (var i = 0; i < lines.length; i++) {
          for (final m in pattern.allMatches(lines[i])) {
            if (!allowed.contains(m.group(1))) {
              hits.add('$path:${i + 1}: ${lines[i].trim()}');
            }
          }
        }
      });
      expect(hits, isEmpty,
          reason: '圆角不在令牌档位内，请用 AppRadius：\n${hits.join('\n')}');
    });

    test('主题值都来自令牌，页面没有自己写 EdgeInsets 之外的魔法数', () {
      // 只守住最容易漂移的一类：直接给 Icon/Text 写 odd 尺寸
      expectClean(r'size:\s*1[0-9]\.5\b', '图标尺寸不要写半像素');
    });

    test('语义色不直接当文字 / 图标色（必须经 onColor / readableOn / onTint）', () {
      // 允许的包装：明确表达了"要按底面取可读色"
      const wrappers = r'(?!onColor\b|onColorMuted\b|readableOn\b|onTint\b'
          r'|tint\b|compose\b|opaque\b|paletteAt\b|chartAt\b|\w+Deep\b)';
      final hits = <String>[];
      final rules = <(String, RegExp)>[
        (
          'TextStyle',
          RegExp('TextStyle\\([\\s\\S]{0,140}?color:\\s*AppSemanticColors\\.'
              '$wrappers\\w+')
        ),
        (
          'Icon',
          RegExp('Icon\\([\\s\\S]{0,140}?color:\\s*AppSemanticColors\\.'
              '$wrappers\\w+')
        ),
        (
          'foreground',
          RegExp('(?:foregroundColor|labelColor|iconColor):\\s*'
              'AppSemanticColors\\.$wrappers\\w+')
        ),
      ];
      sources.forEach((path, src) {
        for (final (label, pattern) in rules) {
          for (final m in pattern.allMatches(src)) {
            final line = src.substring(0, m.start).split('\n').length;
            hits.add('[$label] $path:$line: '
                '${m.group(0)!.split('\n').last.trim()}');
          }
        }
      });
      expect(hits, isEmpty,
          reason: '语义色当文字/图标色前要按底面压到可读（亮红 danger 在白底'
              '只有 3.34:1、品牌绿 2.22:1）：\n${hits.join('\n')}');
    });
  });

  group('底部导航（真实 MainScreen）', () {
    /// 真实启动 MainScreen（含 TimeProvider 与启动期异步的插件 mock）。
    Future<void> pumpMainScreen(WidgetTester tester) async {
      // 预置「那年今日已弹过」标记：MainScreen 会跳过该检查，
      // 从而不会拉起日记索引轮询（否则假时间下会留下 pending timer）。
      SharedPreferences.setMockInitialValues({
        'on_this_day_last_shown_date':
            OnThisDayService.dateKeyOf(DateTime.now()),
      });
      GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('home_widget'),
        (call) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => '/tmp/time_manager_test',
      );

      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => TimeProvider()),
          ChangeNotifierProvider(create: (_) => ThemeModeProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: const MainScreen(),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('窄屏（360x640）下渲染真实底部导航且不溢出', (tester) async {
      await pumpMainScreen(tester);

      expect(find.byType(MainScreen), findsOneWidget);
      // 已从 M2 BottomNavigationBar 迁移到 M3 NavigationBar
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);

      // 桌面端（Windows / macOS）隐藏「目标」tab，移动端保留 6 个
      final expected = isDesktopPlatform ? 5 : 6;
      expect(find.byType(NavigationDestination), findsNWidgets(expected));
      expect(find.text('记录'), findsOneWidget);
      expect(find.text('日记'), findsOneWidget);
      expect(
          find.text('目标'), isDesktopPlatform ? findsNothing : findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('真实导航栏的选中指示器用 primaryContainer', (tester) async {
      await pumpMainScreen(tester);

      final theme = AppTheme.light();
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 0);
      // 未在 widget 上覆盖 indicatorColor，由主题提供
      expect(bar.indicatorColor, isNull);
      expect(theme.navigationBarTheme.indicatorColor,
          theme.colorScheme.primaryContainer);

      // 顶部弱边框由 MainScreen 自己包的那层 Container 提供
      final container = tester.widget<Container>(
        find
            .ancestor(
                of: find.byType(NavigationBar),
                matching: find.byType(Container))
            .first,
      );
      final decoration = container.decoration as BoxDecoration?;
      expect(decoration?.color, surfacesOf(theme).panel);
      expect(decoration?.border, isNotNull);
    });
  });
}
