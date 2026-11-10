import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A CSS float with the block content after it, at block granularity: the
/// first child is the float (at most half the line, [floatWidth] wide), and
/// each following block sits beside it while it starts above the float's
/// bottom, then takes the full width below it. Browsers wrap per line; a
/// block that starts beside the float stays narrow here to its end.
class FloatFlow extends MultiChildRenderObjectWidget {
  const FloatFlow({
    super.key,
    required this.floatWidth,
    required this.right,
    required super.children,
  });

  final double floatWidth;
  final bool right;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderFloatFlow(floatWidth: floatWidth, right: right);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as RenderFloatFlow)
      ..floatWidth = floatWidth
      ..right = right;
  }
}

class _FloatFlowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderFloatFlow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FloatFlowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FloatFlowParentData> {
  RenderFloatFlow({required double floatWidth, required bool right})
    : _floatWidth = floatWidth, // ignore: prefer_initializing_formals
      _right = right; // ignore: prefer_initializing_formals

  double _floatWidth;
  set floatWidth(double value) {
    if (value == _floatWidth) return;
    _floatWidth = value;
    markNeedsLayout();
  }

  bool _right;
  set right(bool value) {
    if (value == _right) return;
    _right = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FloatFlowParentData) {
      child.parentData = _FloatFlowParentData();
    }
  }

  double _floatSlot(double width) =>
      width.isFinite ? math.min(_floatWidth, width / 2) : _floatWidth;

  /// Lays out every child for [width] (or, when [measure], only estimates
  /// heights from intrinsics, as Column does); returns the total height.
  /// Offsets are written only for a real layout.
  double _run(double width, {required bool measure}) {
    final float = firstChild;
    if (float == null) return 0;
    if (!width.isFinite) width = computeMaxIntrinsicWidth(double.infinity);
    final slot = _floatSlot(width);
    final Size floatSize;
    if (measure) {
      final w = math.min(float.getMaxIntrinsicWidth(double.infinity), slot);
      floatSize = Size(w, float.getMaxIntrinsicHeight(w));
    } else {
      float.layout(BoxConstraints(maxWidth: slot), parentUsesSize: true);
      floatSize = float.size;
      (float.parentData! as _FloatFlowParentData).offset = Offset(
        _right ? width - floatSize.width : 0,
        0,
      );
    }
    final besideWidth = math.max(0.0, width - floatSize.width);
    double heightFor(RenderBox child, double childWidth) {
      if (measure) return child.getMaxIntrinsicHeight(childWidth);
      child.layout(
        BoxConstraints.tightFor(width: childWidth),
        parentUsesSize: true,
      );
      return child.size.height;
    }

    var y = 0.0;
    var child = childAfter(float);
    while (child != null) {
      var beside = y < floatSize.height;
      var height = heightFor(child, beside ? besideWidth : width);
      // A browser wraps only the lines beside the float; a block can't
      // split here, so one that would mostly run on below the float starts
      // under it at full width instead of staying narrow to its end.
      if (beside && height > 2 * (floatSize.height - y)) {
        beside = false;
        y = floatSize.height;
        height = heightFor(child, width);
      }
      if (!measure) {
        (child.parentData! as _FloatFlowParentData).offset = Offset(
          beside && !_right ? floatSize.width : 0,
          y,
        );
      }
      y += height;
      child = childAfter(child);
    }
    return math.max(y, floatSize.height);
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : computeMaxIntrinsicWidth(double.infinity);
    size = constraints.constrain(Size(width, _run(width, measure: false)));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final width = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : computeMaxIntrinsicWidth(double.infinity);
    return constraints.constrain(Size(width, _run(width, measure: true)));
  }

  double _widest(double Function(RenderBox child) measure) {
    var widest = 0.0;
    var child = firstChild == null ? null : childAfter(firstChild!);
    while (child != null) {
      widest = math.max(widest, measure(child));
      child = childAfter(child);
    }
    return widest;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final float = firstChild;
    if (float == null) return 0;
    return math.max(
      float.getMinIntrinsicWidth(height),
      _widest((c) => c.getMinIntrinsicWidth(height)),
    );
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final float = firstChild;
    if (float == null) return 0;
    return _floatWidth + _widest((c) => c.getMaxIntrinsicWidth(height));
  }

  @override
  double computeMinIntrinsicHeight(double width) => _run(width, measure: true);

  @override
  double computeMaxIntrinsicHeight(double width) => _run(width, measure: true);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
