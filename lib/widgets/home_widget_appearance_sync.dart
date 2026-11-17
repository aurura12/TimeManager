import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../services/app_log_service.dart';
import '../services/home_widget_service.dart';
import '../services/home_widget_theme.dart';
import '../utils/platform_features.dart';

/// 把 App 当前外观（浅/深 + 主题色）同步到 Android 桌面小组件。
///
/// 只从 [Theme] 取**亮度**，颜色用 `seedColor + brightness` 重算：
/// 启用壁纸时 `AppSurfaces.card` 带透明度，而且 `AnimatedTheme` 切换过程中
/// 颜色是逐帧插值的，直接读 `colorScheme` 会连推十几帧。
///
/// 挂在 `MaterialApp.builder` 上，不参与布局（[build] 原样返回 [child]）。
class HomeWidgetAppearanceSync extends StatefulWidget {
  const HomeWidgetAppearanceSync({
    super.key,
    required this.seedColor,
    required this.followsSystem,
    required this.child,
    this.supported,
  });

  /// 用户在「设置 → 主题色」里选的颜色。
  final Color seedColor;

  /// 外观模式是否为「跟随系统」。
  final bool followsSystem;

  final Widget child;

  /// 仅测试注入；null 时按 [supportsHomeWidget] 判断。
  final bool? supported;

  @override
  State<HomeWidgetAppearanceSync> createState() =>
      _HomeWidgetAppearanceSyncState();
}

class _HomeWidgetAppearanceSyncState extends State<HomeWidgetAppearanceSync>
    with WidgetsBindingObserver {
  String? _lastSignature;
  String? _lastPayload;

  bool get _supported => widget.supported ?? supportsHomeWidget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant HomeWidgetAppearanceSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seedColor != widget.seedColor ||
        oldWidget.followsSystem != widget.followsSystem ||
        oldWidget.supported != widget.supported) {
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 系统「跟随」模式下，App 在后台时切了深浅，回前台补一次。
    if (state == AppLifecycleState.resumed) _sync();
  }

  void _sync() {
    // 非 Android 一律不碰 home_widget 通道（iOS 会抛 AppGroupId not set）。
    if (!_supported) return;

    final brightness = Theme.of(context).brightness;
    final signature =
        '${widget.seedColor.toARGB32()}|${widget.followsSystem}|${brightness.name}';
    if (signature == _lastSignature) return;

    final payload = HomeWidgetTheme.encode(
      seedColor: widget.seedColor,
      resolvedBrightness: brightness,
      followsSystem: widget.followsSystem,
    );
    _lastSignature = signature;
    if (payload == _lastPayload) return;
    _lastPayload = payload;
    unawaited(_push(payload));
  }

  Future<void> _push(String payload) async {
    try {
      await HomeWidgetService.updateAppearance(
        payload,
        supported: _supported,
      );
    } catch (error, stackTrace) {
      // 允许下次重建重试，并把原因留在运行日志里。
      _lastSignature = null;
      _lastPayload = null;
      debugPrint('同步桌面小组件外观失败: $error');
      AppLogService.instance.warning(
        '同步桌面小组件外观失败',
        source: 'home_widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
