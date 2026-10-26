import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../css/html_style.dart';

/// Paints CSS border styles Flutter's [BorderSide] cannot represent.
///
/// Solid sides stay in [BoxDecoration]. This foreground decoration handles
/// dashed, dotted and double sides while sharing the element's border radius.
class CssBorderDecoration extends Decoration {
  const CssBorderDecoration({required this.borders, this.borderRadius});

  final CssBorders borders;
  final BorderRadiusGeometry? borderRadius;

  bool get hasVisiblePatternedSide =>
      _isPatterned(borders.top) ||
      _isPatterned(borders.right) ||
      _isPatterned(borders.bottom) ||
      _isPatterned(borders.left);

  static bool _isPatterned(CssBorderSide? side) =>
      side != null &&
      side.width > 0 &&
      side.color.a > 0 &&
      side.style != CssBorderStyle.none &&
      side.style != CssBorderStyle.solid;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _CssBorderPainter(this);
}

class _CssBorderPainter extends BoxPainter {
  _CssBorderPainter(this.decoration);

  final CssBorderDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    final sides = decoration.borders;
    final uniform = _uniformPatternedSide(sides);
    if (uniform != null) {
      _paintUniform(canvas, rect, uniform);
      return;
    }

    _paintSide(canvas, rect.topLeft, rect.topRight, sides.top);
    _paintSide(canvas, rect.topRight, rect.bottomRight, sides.right);
    _paintSide(canvas, rect.bottomRight, rect.bottomLeft, sides.bottom);
    _paintSide(canvas, rect.bottomLeft, rect.topLeft, sides.left);
  }

  CssBorderSide? _uniformPatternedSide(CssBorders borders) {
    final first = borders.top;
    if (!CssBorderDecoration._isPatterned(first)) return null;
    bool same(CssBorderSide? side) =>
        side != null &&
        side.width == first!.width &&
        side.color == first.color &&
        side.style == first.style;
    return same(borders.right) && same(borders.bottom) && same(borders.left)
        ? first
        : null;
  }

  void _paintUniform(Canvas canvas, Rect rect, CssBorderSide side) {
    final radius = decoration.borderRadius?.resolve(TextDirection.ltr);
    if (side.style == CssBorderStyle.doubleLine) {
      final stroke = side.width / 3;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = side.color;
      final outer = rect.deflate(stroke / 2);
      final inner = rect.deflate(side.width - stroke / 2);
      if (!outer.isEmpty) {
        canvas.drawRRect(
          radius?.toRRect(outer) ?? RRect.fromRectAndRadius(outer, Radius.zero),
          paint,
        );
      }
      if (!inner.isEmpty) {
        canvas.drawRRect(
          radius?.toRRect(inner) ?? RRect.fromRectAndRadius(inner, Radius.zero),
          paint,
        );
      }
      return;
    }
    final inset = side.width / 2;
    final inner = rect.deflate(inset);
    if (inner.isEmpty) return;
    final path = Path()
      ..addRRect(
        radius?.toRRect(inner) ?? RRect.fromRectAndRadius(inner, Radius.zero),
      );
    _paintPath(canvas, path, side);
  }

  void _paintSide(
    Canvas canvas,
    Offset start,
    Offset end,
    CssBorderSide? side,
  ) {
    if (!CssBorderDecoration._isPatterned(side)) return;
    _paintPath(
      canvas,
      Path()
        ..moveTo(start.dx, start.dy)
        ..lineTo(end.dx, end.dy),
      side!,
    );
  }

  void _paintPath(Canvas canvas, Path path, CssBorderSide side) {
    if (side.style == CssBorderStyle.doubleLine) {
      // Mixed per-side doubles cannot share a rounded path. Preserve their
      // authored extent as a solid fallback rather than silently dropping it.
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side.width
        ..color = side.color;
      canvas.drawPath(path, paint);
      return;
    }

    for (final metric in path.computeMetrics()) {
      if (side.style == CssBorderStyle.dotted) {
        final paint = Paint()..color = side.color;
        final radius = side.width / 2;
        final step = math.max(side.width * 2.5, 2.0);
        for (var distance = 0.0; distance < metric.length; distance += step) {
          final tangent = metric.getTangentForOffset(distance);
          if (tangent != null) {
            canvas.drawCircle(tangent.position, radius, paint);
          }
        }
        continue;
      }

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side.width
        ..strokeCap = StrokeCap.butt
        ..color = side.color;
      final dash = math.max(side.width * 4, 3.0);
      final gap = math.max(side.width * 3, 2.0);
      for (
        var distance = 0.0;
        distance < metric.length;
        distance += dash + gap
      ) {
        canvas.drawPath(
          metric.extractPath(
            distance,
            math.min(distance + dash, metric.length),
          ),
          paint,
        );
      }
    }
  }
}
