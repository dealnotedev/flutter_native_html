import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Shrinks an oversized email to fit a narrow viewport, the way a mobile mail
/// client (or a mobile browser's viewport) presents one: the child is laid out
/// at its natural content width, then the whole thing is scaled down to the
/// available width. Content that already fits is left at scale 1.
///
/// [declaredWidthHint] is the widest fixed-pixel width resolved after `@media`.
/// The render object combines it with the child's minimum intrinsic width. The
/// latter captures compound layouts (for example 300px + 300px columns) and
/// unbreakable content, while ordinary wrapping text remains viewport-sized.
class FitToWidth extends SingleChildRenderObjectWidget {
  const FitToWidth({
    super.key,
    required this.declaredWidthHint,
    this.minScale = 0.5,
    required Widget super.child,
  });

  final double declaredWidthHint;

  /// Lower bound for readable text. When the natural layout would require a
  /// smaller scale, the child is re-laid out at `viewport / minScale` so its
  /// painted extent still fits instead of becoming unreachable overflow.
  final double minScale;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderFitToWidth(declaredWidthHint, minScale);

  @override
  void updateRenderObject(BuildContext context, RenderFitToWidth renderObject) {
    renderObject
      ..declaredWidthHint = declaredWidthHint
      ..minScale = minScale;
  }
}

class RenderFitToWidth extends RenderProxyBox {
  RenderFitToWidth(this._declaredWidthHint, this._minScale);

  double _declaredWidthHint;
  set declaredWidthHint(double value) {
    if (value == _declaredWidthHint) return;
    _declaredWidthHint = value;
    markNeedsLayout();
  }

  double _minScale;
  set minScale(double value) {
    if (value == _minScale) return;
    _minScale = value;
    markNeedsLayout();
  }

  double _scale = 1.0;

  double _requiredWidth(RenderBox child) {
    var intrinsic = 0.0;
    try {
      intrinsic = child.getMinIntrinsicWidth(double.infinity);
    } on FlutterError {
      // A custom handler may return a widget that does not support intrinsic
      // dimensions (LayoutBuilder is the common example). The declared-width
      // hint remains a safe fallback in that case.
    }
    if (!intrinsic.isFinite || intrinsic < 0) intrinsic = 0;
    return intrinsic > _declaredWidthHint ? intrinsic : _declaredWidthHint;
  }

  ({double width, double scale}) _fit(RenderBox child, double available) {
    if (!available.isFinite) return (width: available, scale: 1);
    final required = _requiredWidth(child);
    if (required <= available + 0.5) return (width: available, scale: 1);
    final scale = available / required;
    return scale < _minScale
        ? (width: available / _minScale, scale: _minScale)
        : (width: required, scale: scale);
  }

  double _intrinsicHeight(double width, {required bool minimum}) {
    final child = this.child;
    if (child == null) return 0;
    final fit = _fit(child, width);
    final height = minimum
        ? child.getMinIntrinsicHeight(fit.width)
        : child.getMaxIntrinsicHeight(fit.width);
    return height * fit.scale;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, minimum: true);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, minimum: false);

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _scale = 1.0;
      return;
    }
    final fit = _fit(child, constraints.maxWidth);
    _scale = fit.scale;
    if (_scale == 1) {
      child.layout(constraints, parentUsesSize: true);
      size = child.size;
      return;
    }
    child.layout(BoxConstraints(maxWidth: fit.width), parentUsesSize: true);
    size = constraints.constrain(
      Size(constraints.maxWidth, child.size.height * _scale),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final fit = _fit(child, constraints.maxWidth);
    if (fit.scale == 1) return child.getDryLayout(constraints);
    final childSize = child.getDryLayout(BoxConstraints(maxWidth: fit.width));
    return constraints.constrain(
      Size(constraints.maxWidth, childSize.height * fit.scale),
    );
  }

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1.0);

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (_scale == 1.0) {
      context.paintChild(child, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: layer is TransformLayer ? layer as TransformLayer : null,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    if (_scale == 1.0) {
      return child.hitTest(result, position: position);
    }
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_scale != 1.0) transform.multiply(_transform);
  }
}
