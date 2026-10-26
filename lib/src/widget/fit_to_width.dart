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

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _scale = 1.0;
      return;
    }
    final available = constraints.maxWidth;
    final required = _requiredWidth(child);
    if (!available.isFinite || required <= available + 0.5) {
      // Fits already (or unbounded) — render normally.
      _scale = 1.0;
      child.layout(constraints, parentUsesSize: true);
      size = child.size;
      return;
    }
    final naturalScale = available / required;
    _scale = naturalScale.clamp(_minScale, 1.0);
    final layoutWidth = naturalScale < _minScale
        ? available / _minScale
        : required;
    child.layout(BoxConstraints(maxWidth: layoutWidth), parentUsesSize: true);
    size = constraints.constrain(Size(available, child.size.height * _scale));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final available = constraints.maxWidth;
    final required = _requiredWidth(child);
    if (!available.isFinite || required <= available + 0.5) {
      return child.getDryLayout(constraints);
    }
    final naturalScale = available / required;
    final scale = naturalScale.clamp(_minScale, 1.0);
    final layoutWidth = naturalScale < _minScale
        ? available / _minScale
        : required;
    final childSize = child.getDryLayout(BoxConstraints(maxWidth: layoutWidth));
    return constraints.constrain(Size(available, childSize.height * scale));
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
