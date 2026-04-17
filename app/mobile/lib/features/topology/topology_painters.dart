import 'package:flutter/material.dart';

import 'topology_layout.dart';

/// Decorative orbit rings drawn behind the topology canvas.
class OrbitBackdropPainter extends CustomPainter {
  const OrbitBackdropPainter({
    required this.accent,
    required this.secondary,
  });

  final Color accent;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final orbitPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = accent.withValues(alpha: 0.12);
    final secondaryPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = secondary.withValues(alpha: 0.08);

    canvas.drawCircle(
      Offset(size.width * 0.16, size.height * 0.82),
      size.width * 0.28,
      orbitPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.82, size.height * 0.18),
      size.width * 0.22,
      secondaryPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.58, size.height * 0.52),
      size.width * 0.42,
      orbitPaint..color = accent.withValues(alpha: 0.06),
    );
  }

  @override
  bool shouldRepaint(covariant OrbitBackdropPainter oldDelegate) {
    return oldDelegate.accent != accent || oldDelegate.secondary != secondary;
  }
}

/// 64px grid drawn inside the pan/zoom viewport.
class TopologyGridPainter extends CustomPainter {
  const TopologyGridPainter({required this.gridColor});

  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    for (double x = 0; x <= size.width; x += 64) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += 64) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant TopologyGridPainter oldDelegate) {
    return oldDelegate.gridColor != gridColor;
  }
}

/// Cubic-Bezier connectors between topology entities.
class TopologyLinkPainter extends CustomPainter {
  const TopologyLinkPainter({
    required this.layout,
    required this.accent,
  });

  final TopologyLayout layout;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2
      ..color = accent.withValues(alpha: 0.22);

    for (final edge in layout.edges) {
      final path = Path()
        ..moveTo(edge.start.dx, edge.start.dy)
        ..cubicTo(
          edge.start.dx + 120,
          edge.start.dy,
          edge.end.dx - 120,
          edge.end.dy,
          edge.end.dx,
          edge.end.dy,
        );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant TopologyLinkPainter oldDelegate) {
    return oldDelegate.layout != layout || oldDelegate.accent != accent;
  }
}
