import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A table row of px-wide cells, laid out like a browser's auto table on a
/// narrow screen: each cell keeps its width while the row fits, and the
/// [shrinkable] cells narrow in proportion to their widths when it does not
/// (fixed gutters/spacing keep theirs). Every cell then stretches to the
/// tallest cell's height, measured by a real layout rather than intrinsics.
class ProportionalRow extends MultiChildRenderObjectWidget {
  const ProportionalRow({
    super.key,
    required this.widths,
    required this.shrinkable,
    required super.children,
  });

  final List<double> widths;
  final List<bool> shrinkable;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderProportionalRow(widths: widths, shrinkable: shrinkable);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as RenderProportionalRow)
      ..widths = widths
      ..shrinkable = shrinkable;
  }
}

class _RowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderProportionalRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _RowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _RowParentData> {
  RenderProportionalRow({
    required List<double> widths,
    required List<bool> shrinkable,
  }) : _widths = widths, // ignore: prefer_initializing_formals
       _shrinkable = shrinkable; // ignore: prefer_initializing_formals

  List<double> _widths;
  set widths(List<double> value) {
    _widths = value;
    markNeedsLayout();
  }

  List<bool> _shrinkable;
  set shrinkable(List<bool> value) {
    _shrinkable = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _RowParentData) {
      child.parentData = _RowParentData();
    }
  }

  double get _total => _widths.fold(0.0, (s, w) => s + w);

  /// Each child's width for a row at most [maxWidth] wide.
  List<double> _resolve(double maxWidth) {
    final total = _total;
    if (!maxWidth.isFinite || total <= maxWidth) return _widths;
    var fixed = 0.0;
    var flexible = 0.0;
    for (var i = 0; i < _widths.length; i++) {
      if (_shrinkable[i]) {
        flexible += _widths[i];
      } else {
        fixed += _widths[i];
      }
    }
    if (flexible <= 0) return _widths;
    final scale = math.max(0.0, maxWidth - fixed) / flexible;
    return [
      for (var i = 0; i < _widths.length; i++)
        _shrinkable[i] ? _widths[i] * scale : _widths[i],
    ];
  }

  @override
  void performLayout() {
    final widths = _resolve(constraints.maxWidth);
    var height = 0.0;
    var child = firstChild;
    var i = 0;
    while (child != null) {
      child.layout(
        BoxConstraints.tightFor(width: widths[i]),
        parentUsesSize: true,
      );
      height = math.max(height, child.size.height);
      child = childAfter(child);
      i++;
    }
    height = constraints.constrainHeight(height);
    var x = 0.0;
    child = firstChild;
    i = 0;
    while (child != null) {
      // Stretch: backgrounds and borders fill the row, as table cells do.
      if (child.size.height != height) {
        child.layout(
          BoxConstraints.tightFor(width: widths[i], height: height),
          parentUsesSize: true,
        );
      }
      (child.parentData! as _RowParentData).offset = Offset(x, 0);
      x += widths[i];
      child = childAfter(child);
      i++;
    }
    size = constraints.constrain(Size(x, height));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final widths = _resolve(constraints.maxWidth);
    var height = 0.0;
    var child = firstChild;
    var i = 0;
    while (child != null) {
      height = math.max(height, child.getMaxIntrinsicHeight(widths[i]));
      child = childAfter(child);
      i++;
    }
    return constraints.constrain(
      Size(widths.fold(0.0, (s, w) => s + w), height),
    );
  }

  // Like the scaled row this replaces, the row asks for its full width.
  @override
  double computeMinIntrinsicWidth(double height) => _total;

  @override
  double computeMaxIntrinsicWidth(double height) => _total;

  double _intrinsicHeight(double width) {
    final widths = _resolve(width);
    var height = 0.0;
    var child = firstChild;
    var i = 0;
    while (child != null) {
      height = math.max(height, child.getMaxIntrinsicHeight(widths[i]));
      child = childAfter(child);
      i++;
    }
    return height;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

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
