import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/check_in_record.dart';
import '../models/coord_transform.dart';
import '../models/known_google_users.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/map_tile_config.dart';

/// 打卡地图（高德瓦片 + 标记点，WGS-84 → GCJ-02 坐标转换）
class CheckInMapPreview extends StatefulWidget {
  const CheckInMapPreview({
    super.key,
    required this.records,
    this.height = 200,
    this.onTap,
    this.showLegend = true,
    this.tileProvider,
  });

  final List<CheckInRecord> records;
  final double height;
  final VoidCallback? onTap;
  final bool showLegend;

  /// 仅用于测试注入失败/恢复中的瓦片提供器，生产环境保持 flutter_map 默认网络提供器。
  @visibleForTesting
  final TileProvider? tileProvider;

  static final _defaultCenter = () {
    final gcj = CoordTransform.wgs84ToGcj02(39.9042, 116.4074);
    return LatLng(gcj.$1, gcj.$2);
  }();

  @override
  State<CheckInMapPreview> createState() => _CheckInMapPreviewState();
}

class _CheckInMapPreviewState extends State<CheckInMapPreview> {
  final _tileFailureMonitor = MapTileFailureMonitor();
  final _successfulTileKeys = <String>{};
  TileProvider? _ownedTileProvider;
  int _tileLayerGeneration = 0;

  Timer? _failureEvaluationTimer;
  Timer? _automaticRetryTimer;
  Timer? _retryRecoveryTimer;
  bool _showTileFailure = false;
  bool _isRetrying = false;

  @override
  void dispose() {
    _failureEvaluationTimer?.cancel();
    _automaticRetryTimer?.cancel();
    _retryRecoveryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final located = widget.records.where((r) => r.hasLocation).toList();
    final mapData = _aggregateMarkers(located);

    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: AppRadius.cardAll,
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: Stack(
            children: [
              FlutterMap(
                options: MapOptions(
                  initialCenter: mapData.center,
                  initialZoom: mapData.zoom,
                  interactionOptions: InteractionOptions(
                    flags: widget.onTap != null
                        ? InteractiveFlag.none
                        : InteractiveFlag.all,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: MapTileConfig.urlTemplate,
                    subdomains: MapTileConfig.subdomains,
                    userAgentPackageName: MapTileConfig.userAgentPackageName,
                    key: ValueKey<int>(_tileLayerGeneration),
                    tileProvider: _effectiveTileProvider,
                    evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
                    errorTileCallback: _handleTileLoadError,
                    tileBuilder: _observeTileLoad,
                  ),
                  if (mapData.markers.isNotEmpty)
                    MarkerLayer(markers: mapData.markers),
                  if (located.isEmpty) _buildNoLocationState(context),
                  if (_showTileFailure)
                    Positioned.fill(
                      child: _buildTileFailureOverlay(context),
                    ),
                  _buildAttribution(context, surfaces, colorScheme),
                ],
              ),
              if (widget.showLegend && located.isNotEmpty)
                Positioned(
                  left: AppSpacing.sm,
                  bottom: AppSpacing.sm,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: surfaces.card.withValues(alpha: 0.92),
                      borderRadius: AppRadius.controlAll,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_on,
                            size: AppText.caption.fontSize,
                            color: colorScheme.primary),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          '${located.length} 个打卡点',
                          style: AppText.caption.copyWith(
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (widget.onTap != null)
                Positioned(
                  right: AppSpacing.sm,
                  top: AppSpacing.sm,
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.xs),
                    decoration: BoxDecoration(
                      color: surfaces.card.withValues(alpha: 0.92),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.fullscreen,
                        size: 18, color: colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static _MapData _aggregateMarkers(List<CheckInRecord> located) {
    if (located.isEmpty) {
      return _MapData(
        center: CheckInMapPreview._defaultCenter,
        zoom: 11,
        markers: const [],
      );
    }

    // WGS-84 → GCJ-02 转换所有坐标
    final gcjPoints = located.map((r) {
      return CoordTransform.wgs84ToGcj02(r.latitude!, r.longitude!);
    }).toList();

    final lats = gcjPoints.map((p) => p.$1).toList();
    final lngs = gcjPoints.map((p) => p.$2).toList();
    final minLat = lats.reduce(math.min);
    final maxLat = lats.reduce(math.max);
    final minLng = lngs.reduce(math.min);
    final maxLng = lngs.reduce(math.max);

    final center = LatLng(
      (minLat + maxLat) / 2,
      (minLng + maxLng) / 2,
    );

    final latSpan = (maxLat - minLat).abs();
    final lngSpan = (maxLng - minLng).abs();
    final span = math.max(latSpan, lngSpan);
    final zoom = span < 0.002
        ? 15.0
        : span < 0.01
            ? 13.0
            : span < 0.05
                ? 11.0
                : 9.0;

    final counts = <String, int>{};
    for (int i = 0; i < located.length; i++) {
      final p = gcjPoints[i];
      final key = '${p.$1.toStringAsFixed(5)},${p.$2.toStringAsFixed(5)}';
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final markers = <Marker>[];
    final seen = <String>{};
    for (int i = 0; i < located.length; i++) {
      final p = gcjPoints[i];
      final key = '${p.$1.toStringAsFixed(5)},${p.$2.toStringAsFixed(5)}';
      if (seen.contains(key)) continue;
      seen.add(key);
      final count = counts[key] ?? 1;
      final color = _colorForEmail(located[i].userEmail);

      markers.add(
        Marker(
          point: LatLng(p.$1, p.$2),
          width: 44,
          height: 44,
          child: _MapPin(count: count, color: color),
        ),
      );
    }

    return _MapData(center: center, zoom: zoom, markers: markers);
  }

  static Color _colorForEmail(String email) {
    final normalized = KnownGoogleUsers.normalizeEmail(email);
    if (normalized == KnownGoogleUsers.guaiGuaiEmail) {
      return AppSemanticColors.identityGuaiGuai;
    }
    if (normalized == KnownGoogleUsers.jingJingEmail) {
      return AppSemanticColors.identityJingJing;
    }
    return AppSemanticColors.brandSurface;
  }

  Widget _buildNoLocationState(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: surfaces.card.withValues(alpha: 0.86),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                size: AppSizes.iconButton,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '暂无带位置的打卡',
                style: AppText.body.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTileFailureOverlay(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final failedCount = _tileFailureMonitor.failedTileCount;

    return Semantics(
      liveRegion: true,
      label: _isRetrying ? '正在重试地图' : '地图加载失败',
      child: ColoredBox(
        color: surfaces.page.withValues(alpha: 0.88),
        child: Center(
          child: Container(
            constraints:
                const BoxConstraints(maxWidth: AppSizes.dialogMaxWidth),
            margin: const EdgeInsets.all(AppSpacing.md),
            padding: AppSpacing.card,
            decoration: BoxDecoration(
              color: surfaces.card,
              borderRadius: AppRadius.controlAll,
              border: Border.all(color: surfaces.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isRetrying ? Icons.sync : Icons.map_outlined,
                  size: AppSizes.iconButton,
                  color: _isRetrying
                      ? AppSemanticColors.readableOn(
                          AppSemanticColors.warning,
                          surfaces.card,
                        )
                      : AppSemanticColors.readableOn(
                          AppSemanticColors.danger,
                          surfaces.card,
                        ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _isRetrying ? '正在重试地图…' : '地图加载失败',
                  style: AppText.sectionTitle.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _isRetrying ? '正在重新请求地图瓦片，请稍候' : '有 $failedCount 个地图瓦片未能加载。',
                  style: AppText.caption.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (!_isRetrying) ...[
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton.icon(
                    onPressed: _startManualRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试地图'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, AppSizes.button),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAttribution(
    BuildContext context,
    AppSurfaces surfaces,
    ColorScheme colorScheme,
  ) {
    return RichAttributionWidget(
      alignment: AttributionAlignment.bottomRight,
      permanentHeight: AppSizes.minTapTarget,
      showFlutterMapAttribution: false,
      popupBackgroundColor: surfaces.card,
      popupBorderRadius: AppRadius.controlAll,
      attributions: [
        TextSourceAttribution(
          MapTileConfig.attributionSource,
          textStyle: AppText.body.copyWith(color: colorScheme.onSurface),
        ),
        TextSourceAttribution(
          MapTileConfig.privacyNotice,
          prependCopyright: false,
          textStyle: AppText.caption.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
      openButton: (context, open) => _buildAttributionButton(
        context,
        open,
        label: '© ${MapTileConfig.attributionSource}',
        icon: Icons.info_outline,
        semanticLabel: '地图服务与隐私说明',
      ),
      closeButton: (context, close) => _buildAttributionButton(
        context,
        close,
        label: '收起',
        icon: Icons.close,
        semanticLabel: '收起地图服务与隐私说明',
      ),
    );
  }

  Widget _buildAttributionButton(
    BuildContext context,
    VoidCallback onPressed, {
    required String label,
    required IconData icon,
    required String semanticLabel,
  }) {
    final surfaces = AppSurfaces.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        key: const ValueKey<String>('map-attribution-button'),
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadius.badgeAll,
          child: SizedBox(
            height: AppSizes.minTapTarget,
            child: Center(
              child: Ink(
                decoration: BoxDecoration(
                  color: surfaces.card.withValues(alpha: 0.94),
                  borderRadius: AppRadius.badgeAll,
                ),
                child: SizedBox(
                  height: AppSizes.chip,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: AppText.caption.copyWith(
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Icon(
                          icon,
                          size: AppText.caption.fontSize,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _tileKey(TileImage tile) {
    final coordinates = tile.coordinates;
    return '${coordinates.z}/${coordinates.x}/${coordinates.y}';
  }

  void _handleTileLoadError(
    TileImage tile,
    Object _,
    StackTrace? __,
  ) {
    if (!mounted || !_tileFailureMonitor.recordFailure(_tileKey(tile))) {
      return;
    }

    if (!_showTileFailure) {
      setState(() => _showTileFailure = true);
    }
    _retryRecoveryTimer?.cancel();
    _failureEvaluationTimer?.cancel();
    _failureEvaluationTimer = Timer(
      MapTileConfig.failureDisplayDelay,
      _evaluateTileFailures,
    );
  }

  Widget _observeTileLoad(
    BuildContext _,
    Widget tileWidget,
    TileImage tile,
  ) {
    if (!tile.loadError && tile.readyToDisplay) {
      final key = _tileKey(tile);
      if (_successfulTileKeys.add(key)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleTileLoadSuccess();
        });
      }
    }
    return tileWidget;
  }

  void _handleTileLoadSuccess() {
    if (!mounted || !_tileFailureMonitor.hasFailures) return;
    _failureEvaluationTimer?.cancel();
    _automaticRetryTimer?.cancel();
    _automaticRetryTimer = null;
    _retryRecoveryTimer?.cancel();
    _tileFailureMonitor.clearFailures();
    if (!_showTileFailure && !_isRetrying) return;
    setState(() {
      _showTileFailure = false;
      _isRetrying = false;
    });
  }

  void _evaluateTileFailures() {
    if (!mounted || !_tileFailureMonitor.hasFailures) return;
    setState(() {
      _showTileFailure = true;
      _isRetrying = false;
    });

    if (_tileFailureMonitor.shouldAutomaticallyRetry) {
      _scheduleAutomaticRetry();
    }
  }

  void _scheduleAutomaticRetry() {
    if (_automaticRetryTimer != null ||
        !_tileFailureMonitor.shouldAutomaticallyRetry) {
      return;
    }

    setState(() => _isRetrying = true);
    _automaticRetryTimer = Timer(
      _tileFailureMonitor.nextAutomaticRetryDelay,
      () {
        _automaticRetryTimer = null;
        _startAutomaticRetry();
      },
    );
  }

  void _startAutomaticRetry() {
    if (!mounted || !_tileFailureMonitor.beginAutomaticRetry()) return;
    _startTileReset();
  }

  void _startManualRetry() {
    if (!mounted || _isRetrying) return;
    _tileFailureMonitor.beginManualRetry();
    _startTileReset();
  }

  void _startTileReset() {
    _failureEvaluationTimer?.cancel();
    _retryRecoveryTimer?.cancel();
    _successfulTileKeys.clear();
    _tileLayerGeneration++;
    if (widget.tileProvider == null) {
      _ownedTileProvider = NetworkTileProvider();
    }
    setState(() {
      _showTileFailure = true;
      _isRetrying = true;
    });
    _retryRecoveryTimer = Timer(
      MapTileConfig.retryRecoveryWindow,
      _finishRetryObservation,
    );
  }

  void _finishRetryObservation() {
    if (!mounted) return;
    if (_tileFailureMonitor.hasFailures) {
      setState(() => _isRetrying = false);
      return;
    }
    setState(() {
      _showTileFailure = false;
      _isRetrying = false;
    });
  }

  TileProvider get _effectiveTileProvider =>
      widget.tileProvider ?? (_ownedTileProvider ??= NetworkTileProvider());
}

class _MapData {
  const _MapData({
    required this.center,
    required this.zoom,
    required this.markers,
  });

  final LatLng center;
  final double zoom;
  final List<Marker> markers;
}

class _MapPin extends StatelessWidget {
  const _MapPin({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            count > 1 ? '$count' : '',
            style: TextStyle(
              color: AppSemanticColors.onColor(color),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        CustomPaint(
          size: const Size(12, 8),
          painter: _PinTailPainter(color: color),
        ),
      ],
    );
  }
}

class _PinTailPainter extends CustomPainter {
  _PinTailPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = ui.Path()
      ..moveTo(size.width / 2, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PinTailPainter oldDelegate) =>
      oldDelegate.color != color;
}
