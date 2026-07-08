import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/check_in_record.dart';
import '../models/coord_transform.dart';
import '../models/known_google_users.dart';

/// 打卡地图（高德瓦片 + 标记点，WGS-84 → GCJ-02 坐标转换）
class CheckInMapPreview extends StatelessWidget {
  const CheckInMapPreview({
    super.key,
    required this.records,
    this.height = 200,
    this.onTap,
    this.showLegend = true,
  });

  final List<CheckInRecord> records;
  final double height;
  final VoidCallback? onTap;
  final bool showLegend;

  static final _defaultCenter = () {
    final gcj = CoordTransform.wgs84ToGcj02(39.9042, 116.4074);
    return LatLng(gcj.$1, gcj.$2);
  }();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final located = records.where((r) => r.hasLocation).toList();
    final mapData = _aggregateMarkers(located);

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            children: [
              FlutterMap(
                options: MapOptions(
                  initialCenter: mapData.center,
                  initialZoom: mapData.zoom,
                  interactionOptions: InteractionOptions(
                    flags: onTap != null
                        ? InteractiveFlag.none
                        : InteractiveFlag.all,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://webrd{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                    subdomains: const ['01', '02', '03', '04'],
                    userAgentPackageName: 'com.example.time_manager',
                  ),
                  if (mapData.markers.isNotEmpty)
                    MarkerLayer(markers: mapData.markers),
                ],
              ),
              if (located.isEmpty)
                Container(
                  color: colorScheme.surface.withValues(alpha: 0.72),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.map_outlined,
                          size: 36,
                          color: colorScheme.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text(
                        '暂无带位置的打卡',
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              if (showLegend && located.isNotEmpty)
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: colorScheme.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_on,
                            size: 14, color: colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          '${located.length} 个打卡点',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (onTap != null)
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: colorScheme.surface.withValues(alpha: 0.92),
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
      return _MapData(center: _defaultCenter, zoom: 11, markers: const []);
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
      return const Color(0xFF4DA8EE);
    }
    if (normalized == KnownGoogleUsers.jingJingEmail) {
      return const Color(0xFFF16B77);
    }
    return const Color(0xFF96B462);
  }
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
            style: const TextStyle(
              color: Colors.white,
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
