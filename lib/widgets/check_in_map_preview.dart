import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/check_in_record.dart';

/// 地图预览（UI 原型，非真实地图 SDK）
class CheckInMapPreview extends StatelessWidget {
  const CheckInMapPreview({
    super.key,
    required this.records,
    this.height = 180,
    this.onTap,
    this.showLegend = true,
  });

  final List<CheckInRecord> records;
  final double height;
  final VoidCallback? onTap;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final located = records.where((r) => r.hasLocation).toList();

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _MockMapPainter(
                  records: located,
                  pinColor: colorScheme.primary,
                ),
              ),
              if (showLegend)
                Positioned(
                  left: 12,
                  bottom: 12,
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
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (onTap != null)
                Positioned(
                  right: 12,
                  top: 12,
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
}

class _MockMapPainter extends CustomPainter {
  _MockMapPainter({required this.records, required this.pinColor});

  final List<CheckInRecord> records;
  final Color pinColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 背景
    final bgPaint = Paint()..color = const Color(0xFFE8F0E3);
    canvas.drawRect(Offset.zero & size, bgPaint);

    // 网格线
    final gridPaint = Paint()
      ..color = const Color(0xFFCDD8C5)
      ..strokeWidth = 0.5;
    const gridStep = 24.0;
    for (var x = 0.0; x < size.width; x += gridStep) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 0.0; y < size.height; y += gridStep) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // 模拟道路
    final roadPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(0, size.height * 0.4),
      Offset(size.width, size.height * 0.55),
      roadPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.3, 0),
      Offset(size.width * 0.5, size.height),
      roadPaint,
    );

    if (records.isEmpty) return;

    // 将经纬度映射到画布坐标
    final lats = records.map((r) => r.latitude!).toList();
    final lngs = records.map((r) => r.longitude!).toList();
    final minLat = lats.reduce(math.min);
    final maxLat = lats.reduce(math.max);
    final minLng = lngs.reduce(math.min);
    final maxLng = lngs.reduce(math.max);
    final latRange = (maxLat - minLat).clamp(0.001, double.infinity);
    final lngRange = (maxLng - minLng).clamp(0.001, double.infinity);

    // 统计同位置打卡次数
    final counts = <String, int>{};
    for (final r in records) {
      final key = '${r.latitude!.toStringAsFixed(4)},${r.longitude!.toStringAsFixed(4)}';
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final drawn = <String>{};
    for (final r in records) {
      final key = '${r.latitude!.toStringAsFixed(4)},${r.longitude!.toStringAsFixed(4)}';
      if (drawn.contains(key)) continue;
      drawn.add(key);

      final nx = (r.longitude! - minLng) / lngRange;
      final ny = 1 - (r.latitude! - minLat) / latRange;
      final x = 24 + nx * (size.width - 48);
      final y = 24 + ny * (size.height - 48);
      final count = counts[key] ?? 1;

      _drawPin(canvas, Offset(x, y), count);
    }
  }

  void _drawPin(Canvas canvas, Offset center, int count) {
    final radius = 14.0 + math.min(count - 1, 4) * 3.0;

    // 阴影
    canvas.drawCircle(
      center + const Offset(1, 2),
      radius,
      Paint()..color = Colors.black.withValues(alpha: 0.15),
    );

    // 外圈
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = pinColor.withValues(alpha: 0.25),
    );

    // 内圈
    canvas.drawCircle(center, radius * 0.65, Paint()..color = pinColor);

    // 数字
    if (count > 1) {
      final tp = TextPainter(
        text: TextSpan(
          text: '$count',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        center - Offset(tp.width / 2, tp.height / 2),
      );
    } else {
      canvas.drawCircle(
        center,
        3,
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MockMapPainter oldDelegate) =>
      oldDelegate.records != records || oldDelegate.pinColor != pinColor;
}
