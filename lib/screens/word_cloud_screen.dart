import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';

class WordCloudScreen extends StatefulWidget {
  const WordCloudScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WordCloudScreen()),
    );
  }

  @override
  State<WordCloudScreen> createState() => _WordCloudScreenState();
}

class _WordCloudScreenState extends State<WordCloudScreen> {
  _WordCloudShape _shape = _WordCloudShape.whale;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimeProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final start = DateTime(2020, 1, 1);
    final durationStats = provider.getStatistics(start, now);
    final occurrenceStats = provider.getEventOccurrenceCounts(start, now);
    final words = _buildWordCloudItems(durationStats, occurrenceStats);

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(
          '事件词云',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
      ),
      body: words.isEmpty
          ? Center(
              child: Text('暂无可用于生成词云的数据',
                  style: TextStyle(color: colorScheme.onSurfaceVariant)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '词云权重 = 70%时长 + 30%出现次数（按所有历史记录统计）',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _WordCloudShape.values.map((shape) {
                          return ChoiceChip(
                            label: Text(shape.label),
                            selected: _shape == shape,
                            onSelected: (_) {
                              setState(() => _shape = shape);
                            },
                            selectedColor: colorScheme.primaryContainer,
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _buildWordCloudCard(words),
                const SizedBox(height: 14),
                _buildTopList(words),
              ],
            ),
    );
  }

  Widget _buildWordCloudCard(List<_WordCloudItem> words) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 430,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final placed = _layoutWords(words, size, _shape);

          return Stack(
            children: [
              for (final word in placed)
                Positioned(
                  left: word.rect.left,
                  top: word.rect.top,
                  child: Tooltip(
                    message:
                        '${word.item.label}\n时长: ${word.item.hours.toStringAsFixed(2)}h\n出现: ${word.item.occurrences}次',
                    child: Text(
                      word.item.label,
                      style: TextStyle(
                        fontSize: word.fontSize,
                        color: word.color,
                        fontWeight: word.fontSize > 24
                            ? FontWeight.w700
                            : FontWeight.w500,
                        height: 1.05,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  List<_PlacedWord> _layoutWords(
    List<_WordCloudItem> words,
    Size size,
    _WordCloudShape shape,
  ) {
    if (size.width <= 0 || size.height <= 0) return const [];
    final rng = math.Random(100 + shape.index);
    final maxWeight =
        words.map((e) => e.weight).fold<double>(0, (a, b) => a > b ? a : b);
    final minWeight =
        words.map((e) => e.weight).fold<double>(words.first.weight, (a, b) {
      return a < b ? a : b;
    });

    final placed = <_PlacedWord>[];
    for (var i = 0; i < words.length; i++) {
      final item = words[i];
      final normalized = (maxWeight - minWeight).abs() < 0.0001
          ? 1.0
          : ((item.weight - minWeight) / (maxWeight - minWeight))
              .clamp(0.0, 1.0);
      final baseFont = 12.0 + normalized * 26.0;
      final color = Color.lerp(
        const Color(0xFF6B8E3A),
        const Color(0xFF4A90E2),
        (i % 6) / 5,
      )!;

      _PlacedWord? word;
      for (final scale in [1.0, 0.9, 0.8]) {
        word = _tryPlaceWord(
          item: item,
          fontSize: baseFont * scale,
          color: color,
          size: size,
          shape: shape,
          placed: placed,
          rng: rng,
        );
        if (word != null) break;
      }

      if (word != null) placed.add(word);
    }
    return placed;
  }

  _PlacedWord? _tryPlaceWord({
    required _WordCloudItem item,
    required double fontSize,
    required Color color,
    required Size size,
    required _WordCloudShape shape,
    required List<_PlacedWord> placed,
    required math.Random rng,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: item.label,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final textSize = tp.size;
    if (textSize.width <= 0 || textSize.height <= 0) return null;

    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) * 0.48;
    const attempts = 420;

    for (var attempt = 0; attempt < attempts; attempt++) {
      final t = attempt / attempts;
      final angle = attempt * 0.35;
      final radius = maxRadius * t;
      final jitterX = (rng.nextDouble() - 0.5) * 18;
      final jitterY = (rng.nextDouble() - 0.5) * 18;
      final x = center.dx + math.cos(angle) * radius + jitterX;
      final y = center.dy + math.sin(angle) * radius + jitterY;
      final rect = Rect.fromCenter(
        center: Offset(x, y),
        width: textSize.width,
        height: textSize.height,
      );

      if (rect.left < 0 ||
          rect.top < 0 ||
          rect.right > size.width ||
          rect.bottom > size.height) {
        continue;
      }
      if (!_isRectInsideShape(rect, size, shape)) continue;

      var overlapped = false;
      for (final p in placed) {
        if (rect.overlaps(p.rect.inflate(3.5))) {
          overlapped = true;
          break;
        }
      }
      if (!overlapped) {
        return _PlacedWord(
          item: item,
          rect: rect,
          fontSize: fontSize,
          color: color,
        );
      }
    }
    return null;
  }

  bool _isRectInsideShape(Rect rect, Size size, _WordCloudShape shape) {
    final points = <Offset>[
      rect.center,
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
      Offset(rect.center.dx, rect.top),
      Offset(rect.center.dx, rect.bottom),
      Offset(rect.left, rect.center.dy),
      Offset(rect.right, rect.center.dy),
    ];

    for (final p in points) {
      final nx = (p.dx - size.width / 2) / (size.width * 0.45);
      final ny = (p.dy - size.height / 2) / (size.height * 0.45);
      if (!_isInsideShape(nx, ny, shape)) return false;
    }
    return true;
  }

  bool _isInsideShape(double x, double y, _WordCloudShape shape) {
    switch (shape) {
      case _WordCloudShape.circle:
        return x * x + y * y <= 1.0;
      case _WordCloudShape.heart:
        final hy = -y;
        final v = math.pow(x * x + hy * hy - 1, 3) - x * x * math.pow(hy, 3);
        return v <= 0;
      case _WordCloudShape.whale:
        final body = ((x + 0.05) * (x + 0.05)) / (0.80 * 0.80) +
                (y * y) / (0.52 * 0.52) <=
            1;
        final head = ((x - 0.52) * (x - 0.52)) / (0.33 * 0.33) +
                ((y + 0.02) * (y + 0.02)) / (0.24 * 0.24) <=
            1;
        final tailTop = _pointInTriangle(
          Offset(x, y),
          const Offset(-0.68, -0.02),
          const Offset(-1.02, -0.33),
          const Offset(-0.86, -0.01),
        );
        final tailBottom = _pointInTriangle(
          Offset(x, y),
          const Offset(-0.68, 0.02),
          const Offset(-1.02, 0.33),
          const Offset(-0.86, 0.01),
        );
        final mouthCut = x > 0.70 && y < -0.10;
        return (body || head || tailTop || tailBottom) && !mouthCut;
    }
  }

  bool _pointInTriangle(Offset p, Offset a, Offset b, Offset c) {
    final area = (b.dx - a.dx) * (c.dy - a.dy) - (c.dx - a.dx) * (b.dy - a.dy);
    final s = ((a.dy - c.dy) * (p.dx - c.dx) +
            (c.dx - a.dx) * (p.dy - c.dy)) /
        area;
    final t = ((c.dy - b.dy) * (p.dx - c.dx) +
            (b.dx - c.dx) * (p.dy - c.dy)) /
        area;
    final u = 1 - s - t;
    return s >= 0 && t >= 0 && u >= 0;
  }

  Widget _buildTopList(List<_WordCloudItem> words) {
    final colorScheme = Theme.of(context).colorScheme;
    final top = words.take(12).toList();
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: ListView.separated(
        itemCount: top.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        separatorBuilder: (_, __) =>
            Divider(height: 1, color: colorScheme.outlineVariant),
        itemBuilder: (context, index) {
          final item = top[index];
          return ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 12,
              backgroundColor: colorScheme.primaryContainer,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            title: Text(
              item.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '时长 ${item.hours.toStringAsFixed(2)}h · 出现 ${item.occurrences}次',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          );
        },
      ),
    );
  }

  List<_WordCloudItem> _buildWordCloudItems(
    Map<String, double> durationStats,
    Map<String, int> occurrenceStats,
  ) {
    final items = <_WordCloudItem>[];
    for (final entry in durationStats.entries) {
      final label = entry.key.trim();
      if (label.isEmpty) continue;
      final hours = entry.value;
      final occurrences = occurrenceStats[label] ?? 0;
      final weight = hours * 0.7 + occurrences * 0.3;
      items.add(_WordCloudItem(
        label: label,
        hours: hours,
        occurrences: occurrences,
        weight: weight,
      ));
    }

    items.sort((a, b) => b.weight.compareTo(a.weight));
    return items.take(45).toList();
  }
}

enum _WordCloudShape {
  whale('鲸鱼'),
  heart('爱心'),
  circle('圆形');

  final String label;
  const _WordCloudShape(this.label);
}

class _WordCloudItem {
  final String label;
  final double hours;
  final int occurrences;
  final double weight;

  _WordCloudItem({
    required this.label,
    required this.hours,
    required this.occurrences,
    required this.weight,
  });
}

class _PlacedWord {
  final _WordCloudItem item;
  final Rect rect;
  final double fontSize;
  final Color color;

  _PlacedWord({
    required this.item,
    required this.rect,
    required this.fontSize,
    required this.color,
  });
}

